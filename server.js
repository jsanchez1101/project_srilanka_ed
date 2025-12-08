//using parametrized queries

require('dotenv').config();

const express = require('express');
const mysql = require('mysql2/promise');
const stripe = require('stripe')(process.env.STRIPE_KEY);
const cors = require('cors');

const app = express();

/* -------------------------------------------------
   1. CORS (enable browser donations)
---------------------------------------------------*/
app.use(cors({
  origin: [
    "https://final-sl.onrender.com",
    "https://project-srilanka-ed.onrender.com",
    "http://localhost:5500"
  ]
}));

/* -------------------------------------------------
   2. STRIPE WEBHOOK (RAW BODY — MUST BE FIRST)
---------------------------------------------------*/
app.post('/webhook', express.raw({ type: 'application/json' }), async (req, res) => {
  const sig = req.headers['stripe-signature'];
  let event;

  try {
    event = stripe.webhooks.constructEvent(
      req.body,
      sig,
      process.env.STRIPE_HOOK
    );
  } catch (err) {
    console.error("Webhook error:", err.message);
    return res.status(400).send(`Webhook Error: ${err.message}`);
  }

  try {
    if (event.type === 'checkout.session.completed') {
      const session = event.data.object;
      console.log("Payment success session:", session.id);

      await handleCheckoutCompleted(session, event.id);
    }

    return res.json({ received: true });
  } catch (e) {
    console.error("Webhook handler error:", e);
    return res.status(500).json({ received: true, handled: false });
  }
});

/* -------------------------------------------------
   3. JSON BODY PARSER (AFTER WEBHOOK)
---------------------------------------------------*/
app.use(express.json());

console.log("--ENV--");
console.log("DB HOST:", process.env.DB_HOST);
console.log("PORT:", process.env.DONATIONS_PORT);
console.log("USER:", process.env.DB_USER);
console.log("NAME:", process.env.DB_NAME);

/* -------------------------------------------------
   4. MYSQL CONNECTION POOL
---------------------------------------------------*/
const pool = mysql.createPool({
  host: process.env.DB_HOST,
  port: Number(process.env.DONATIONS_PORT),
  user: process.env.DB_USER,
  password: process.env.DB_PASS,
  database: process.env.DB_NAME,
  waitForConnections: true,
  connectionLimit: 10,
  queueLimit: 100
});

/* -------------------------------------------------
   5. HEALTH + SIMPLE ROUTES
---------------------------------------------------*/
app.get('/', (req, res) => {
  res.send('Prototype 1: Express + MariaDB live');
});

app.get('/health', async (_req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ ok: true, db: "up" });
  } catch (err) {
    res.status(500).json({ ok: false, db: "down", error: err.message });
  }
});

/* -------------------------------------------------
   6. GET LATEST DONORS (OPTIONAL)
---------------------------------------------------*/
app.get('/donors', async (_req, res) => {
  const [rows] = await pool.query(
    "SELECT fullname, email, country, created_at FROM donor ORDER BY created_at DESC LIMIT 5"
  );
  res.json(rows);
});

/* -------------------------------------------------
   7. STRIPE CHECKOUT SESSION
---------------------------------------------------*/
app.post('/create-checkout-session', async (req, res) => {
  try {
    const { amount, campaign_id, recipient_id } = req.body;

    // Convert into USD cents (default $5)
    const amountCents = Math.max(100, Number(amount) || 500);

    const session = await stripe.checkout.sessions.create({
      mode: "payment",
      line_items: [
        {
          price_data: {
            currency: "usd",
            product_data: { name: "Malky Donation" },
            unit_amount: amountCents,
          },
          quantity: 1,
        }
      ],
      success_url: "https://example.com/success",
      cancel_url: "https://example.com/cancel",
      metadata: {
        campaign_id: campaign_id || "1",
        recipient_id: recipient_id || "some-uuid"
      }
    });

    res.json({ url: session.url, session_id: session.id });
  } catch (err) {
    console.error("Stripe error:", err);
    res.status(500).json({ error: err.message });
  }
});

/* -------------------------------------------------
   8. HANDLE CHECKOUT COMPLETION (DATABASE WRITES)
---------------------------------------------------*/
async function handleCheckoutCompleted(session, eventId) {
  const conn = await pool.getConnection();

  try {
    await conn.beginTransaction();

    // Idempotency (ignore duplicate Stripe events)
    await conn.execute(
      `INSERT INTO webhook_event (stripe_event_id, type, payload_json, processed_at)
       VALUES (?, ?, ?, NOW())`,
      [eventId, "checkout.session.completed", JSON.stringify(session)]
    );

    // Donor upsert
    const email = session?.customer_details?.email || null;
    const name = session?.customer_details?.name || null;

    let donorId = null;

    if (email) {
      const [existing] = await conn.execute(
        "SELECT donor_id FROM donor WHERE email = ? LIMIT 1",
        [email]
      );

      if (existing.length) {
        donorId = existing[0].donor_id;
      } else {
        await conn.execute(
          "INSERT INTO donor (donor_id, fullname, email, country) VALUES (UUID(), ?, ?, NULL)",
          [name || null, email]
        );

        const [newDonor] = await conn.execute(
          "SELECT donor_id FROM donor WHERE email = ? LIMIT 1",
          [email]
        );

        donorId = newDonor[0].donor_id;
      }
    }

    // Payment details
    const piId = session.payment_intent || null;
    const coId = session.id;
    const amount = session.amount_total || 0;
    const currency = (session.currency || "usd").toUpperCase();
    const campaignId = session.metadata?.campaign_id || null;
    const recipientId = session.metadata?.recipient_id || null;

    // Check for existing payment
    const [existingPayment] = await conn.execute(
      "SELECT payment_id FROM payment WHERE stripe_payment_intent_id = ? OR stripe_checkout_id = ? LIMIT 1",
      [piId, coId]
    );

    let paymentId;

    if (existingPayment.length) {
      paymentId = existingPayment[0].payment_id;

      await conn.execute(
        `UPDATE payment
           SET status = 'success',
               amount_minor = ?,
               currency = ?,
               donor_id = COALESCE(donor_id, ?),
               campaign_id = COALESCE(campaign_id, ?),
               recipient_id = COALESCE(recipient_id, ?)
         WHERE payment_id = ?`,
        [amount, currency, donorId, campaignId, recipientId, paymentId]
      );
    } else {
      const [insert] = await conn.execute(
        `INSERT INTO payment
           (donor_id, recipient_id, campaign_id, amount_minor, currency, status,
            stripe_payment_intent_id, stripe_checkout_id)
         VALUES (?, ?, ?, ?, ?, 'success', ?, ?)`,
        [donorId, recipientId, campaignId, amount, currency, piId, coId]
      );

      paymentId = insert.insertId;
    }

    // Add transaction trail entry
    await conn.execute(
      `INSERT INTO transaction_trail (payment_id, entry_type, amount_minor, currency)
       VALUES (?, 'payment_succeeded', ?, ?)`,
      [paymentId, amount, currency]
    );

    await conn.commit();
  } catch (err) {
    await conn.rollback();

    if (err.code === "ER_DUP_ENTRY") return; // safe ignore

    throw err;
  } finally {
    conn.release();
  }
}

/* -------------------------------------------------
   9. START SERVER (RENDER COMPATIBLE)
---------------------------------------------------*/
const PORT = process.env.PORT || 3000;
app.listen(PORT, () =>
  console.log(`Server running on port ${PORT}`)
);
