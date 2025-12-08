//using parametrized queries

require('dotenv').config();

const express = require('express');
const mysql = require('mysql2/promise');
const stripe = require('stripe')(process.env.STRIPE_KEY);
const cors = require('cors');

const app = express();


//Stripe webhook endpoint
//Listens for events from stripe, veriies using Stripe signature and key.
app.post('/webhook', express.raw({ type: 'application/json' }), async (req, res) => {
  const sig = req.headers['stripe-signature'];
  let event;

  //event handling
  try {
    event = stripe.webhooks.constructEvent(req.body, sig, process.env.STRIPE_HOOK);
  } catch (err) {
    console.error('Webhook error:', err.message);
    return res.status(400).send(`Webhook Error: ${err.message}`);
  }

  try {
    if (event.type === 'checkout.session.completed') {
      const session = event.data.object;
      console.log('Payment succeeded for session:', session.id);
      await handleCheckoutCompleted(session, event.id); // write to DB (idempotent)
    }
    return res.json({ received: true });
  } catch (e) {
    // acknowledge so Stripe doesn’t retry forever on our app error
    console.error('Webhook handler error:', e);
    return res.status(500).json({ received: true, handled: false });
  }
});

// AFTER webhook, enable JSON for normal routes
app.use(express.json());

console.log('--ENV--');
console.log('DB HOST: ', process.env.DB_HOST);
console.log('port:', process.env.DONATIONS_PORT);
console.log('user: ', process.env.DB_USER);
console.log('name: ', process.env.DB_NAME);

// Database connection pool (for multiple reusable connections)
//using bc of multiple HTTP donor requests at same time to avoid clog
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

// Root route
app.get('/', (req, res) => {
  res.send('Prototype 1: Express + MariaDB live');
});

// Health check route
app.get('/health', async (_req, res) => {
  try {
    const [result] = await pool.query('SELECT 1');
    res.json({ ok: true, db: 'up' });
  } catch (err) {
    res.status(500).json({ ok: false, db: 'down', error: err.message });
  }
});

// Donor routes
app.get('/donors', async (_req, res) => {
  const [rows] = await pool.query(
    'SELECT fullname, email, country, created_at FROM donor ORDER BY created_at DESC LIMIT 5'
  );
  res.json(rows);
});

//checkout session
app.post('/create-checkout-session', async (req, res) => {
  try {
    const session = await stripe.checkout.sessions.create({
      mode: 'payment',
      line_items: [
        {
          price_data: {
            currency: 'usd',
            product_data: { name: 'Malky Donation' },
            unit_amount: 500,
          },
          quantity: 1,
        }
      ],
      //
      success_url: 'https://example.com/success',
      cancel_url: 'https://example.com/cancel',
      metadata: { campaign_id: '1', recipient_id: 'some-uuid' }
    });
    res.json({ url: session.url, session_id: session.id });
  } catch (err) {
    console.error('Stripe error', err);
    res.status(500).json({ error: err.message });
  }
});

/*Donor creation endpoint backup. Grandfathered in, will not be used in this project.
recieves Json input from client and inserts into db. UUID for uniqeuness

app.post('/donors', async (req, res) => {
  const { fullname, email, country } = req.body;
  /*parameterized query below to prevent SQL injection
  // (input is treated as data only, not possible to hijack
  // by inputting a SQL cmnd)
  await pool.execute(
    'INSERT INTO donor (donor_id, fullname, email, country) VALUES (UUID(), ?, ?, ?)',
    [fullname, email, country || null]
  );
  res.status(201).json({ message: 'Donor added!' });
});
*/

/**
 * Writes a successful checkout into our donationsDB with idempotency(no dupes) for security
    webhook_event insert (UNIQUE stripe_event_id)
    donor upsert by email
    payment insert/update
    transaction_trail append
 */
async function handleCheckoutCompleted(session, eventId) {
  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();

    // Idempotency aka throw on duplicate. security.
    await conn.execute(
      `INSERT INTO webhook_event (stripe_event_id, type, payload_json, processed_at)
       VALUES (?, ?, ?, NOW())`,
      [eventId, 'checkout.session.completed', JSON.stringify(session)]
    );

    // Upsert donor by email
    const email = session?.customer_details?.email || null;
    const name  = session?.customer_details?.name  || null;
    let donorId = null;

    if (email) {
      const [d1] = await conn.execute(
        'SELECT donor_id FROM donor WHERE email = ? LIMIT 1',
        [email]
      );
      if (d1.length) {
        donorId = d1[0].donor_id;
      } else {
        await conn.execute(
          'INSERT INTO donor (donor_id, fullname, email, country) VALUES (UUID(), ?, ?, NULL)',
          [name || null, email]
        );
        const [d2] = await conn.execute(
          'SELECT donor_id FROM donor WHERE email = ? LIMIT 1',
          [email]
        );
        donorId = d2[0].donor_id;
      }
    }

    // Map session to payment fields 
    const piId        = session.payment_intent || null;
    const coId        = session.id;
    const amount      = session.amount_total || 0;
    const currency    = (session.currency || 'usd').toUpperCase();
    const campaignId  = session.metadata?.campaign_id || null;
    const recipientId = session.metadata?.recipient_id || null; // note: metadata key uses underscore

    // Insert or update payment
    const [pExisting] = await conn.execute(
      'SELECT payment_id FROM payment WHERE stripe_payment_intent_id = ? OR stripe_checkout_id = ? LIMIT 1',
      [piId, coId]
    );

    let paymentId;
    if (pExisting.length) {
      paymentId = pExisting[0].payment_id;

      // ensuring status reflects success, amount etc
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
      const [ins] = await conn.execute(
        `INSERT INTO payment
           (donor_id, recipient_id, campaign_id, amount_minor, currency, status,
            stripe_payment_intent_id, stripe_checkout_id)
         VALUES (?, ?, ?, ?, ?, 'success', ?, ?)`,
        [donorId, recipientId, campaignId, amount, currency, piId, coId]
      );
      paymentId = ins.insertId;
    }

    // Appending transaction_trail record
    await conn.execute(
      `INSERT INTO transaction_trail
         (payment_id, entry_type, amount_minor, currency)
       VALUES (?, 'payment_succeeded', ?, ?)`,
      [paymentId, amount, currency]
    );

    await conn.commit();
  } catch (e) {
    await conn.rollback();

    // ignore duplicate webhook events
    if (e && String(e.code).toUpperCase() === 'ER_DUP_ENTRY') {
      return;
    }
    throw e;
  } finally {
    conn.release();
  }
}

app.listen(3000, () => console.log('Server running on port 3000'));
