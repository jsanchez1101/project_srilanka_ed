//using parametrized queries

require('dotenv').config();

const express = require('express');
const mysql = require('mysql2/promise');

const app = express();
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
  waitForConnections: true, //preventing 
  connectLimit:10,
  queueLimit:100
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

app.post('/donors', async (req, res) => {
  const { fullname, email, country } = req.body;
  await pool.execute(
    'INSERT INTO donor (donor_id, fullname, email, country) VALUES (UUID(), ?, ?, ?)',
    [fullname, email, country || null]
  );
  res.status(201).json({ message: 'Donor added!' });
});

app.listen(3000, () => console.log('Server running on port 3000'));
