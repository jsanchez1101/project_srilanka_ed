-- schema (stripe checkout intake + webhook-first; off-platform payouts tracked internally)

create database if not exists donationsdb
  default character set utf8mb4
  collate utf8mb4_unicode_ci;

use donationsdb;

set time_zone = '+00:00';

-- donors id'd by email from webhook session.customer_details
create table if not exists donor (
  donor_id        char(36) primary key,
  fullname        varchar(200) not null,
  email           varchar(255) not null unique,
  country         varchar(2) null,
  public_opt_in   tinyint(1) not null default 0,
  created_at      timestamp default current_timestamp,
  updated_at      timestamp default current_timestamp on update current_timestamp,
  constraint chk_donor_country_len check (country is null or char_length(country) = 2)
) engine=innodb default charset=utf8mb4;


-- recipients. stripe_account_id stays null for sri lankans
create table if not exists recipient (
  recipient_id      char(36) primary key,
  full_name         varchar(100) not null,
  email             varchar(100) not null unique,
  stripe_account_id varchar(64) unique,
  charges_enabled   boolean default false,
  created_at        timestamp default current_timestamp,
  updated_at        timestamp default current_timestamp on update current_timestamp,
  constraint chk_recipient_stripe_guard check (charges_enabled = 0 or stripe_account_id is not null)
) engine=innodb default charset=utf8mb4;

-- 
create table if not exists recipient_payout_details (
  recipient_id      char(36) primary key,
  wise_profile_id   varchar(64) null,
  bank_account_name varchar(100) null,
  bank_account_no   varchar(64) null,
  bank_code         varchar(20) null,        -- optional for Sri Lanka banks
  swift_code        varchar(20) null,
  created_at        timestamp default current_timestamp,
  updated_at        timestamp default current_timestamp on update current_timestamp,

  constraint fk_rpd_recipient
    foreign key (recipient_id) references recipient(recipient_id)
    on update cascade on delete cascade
);

-- payments are written/updated by webhooks (checkout.session.completed)
create table if not exists payment (
  payment_id               bigint unsigned primary key auto_increment,
  donor_id                 char(36) not null,
  recipient_id             char(36) null,
  amount_minor             int unsigned not null,
  currency                 char(3) not null,
  status                   enum('pending','success','failed','refunded') not null default 'pending',
  stripe_payment_intent_id varchar(64) unique,
  stripe_checkout_id       varchar(64) unique,
  amount_minor_usd         int unsigned null,  -- optional normalized reporting
  created_at               timestamp default current_timestamp,
  updated_at               timestamp default current_timestamp on update current_timestamp,

  constraint fk_payment_donor
    foreign key (donor_id) references donor(donor_id)
    on update cascade on delete restrict,

  constraint fk_payment_recipient
    foreign key (recipient_id) references recipient(recipient_id)
    on update cascade on delete set null,

  key idx_payment_donor (donor_id),
  key idx_payment_recipient (recipient_id),
  key idx_payment_status (status),

  constraint chk_payment_amount_pos check (amount_minor > 0),
  constraint chk_payment_currency_len check (char_length(currency) = 3)
) engine=innodb default charset=utf8mb4;

-- raw stripe events; unique(event_id) = idempotency guard(only one execution)
create table if not exists webhook_event (
  webhook_event_id bigint unsigned primary key auto_increment,
  stripe_event_id  varchar(64) not null unique,
  type             varchar(64) not null,
  payload_json     json null,
  error_message    varchar(500) null,
  received_at      timestamp default current_timestamp,
  processed_at     timestamp null,
  key idx_webhook_type (type)
) engine=innodb default charset=utf8mb4;

-- immutable ledger entries linked to payment for audit
create table if not exists transaction_trail (
  entry_id     bigint unsigned primary key auto_increment,
  payment_id   bigint unsigned not null,
  entry_type   enum(
                  'intent_created','payment_succeeded','transfer_out','fee','refund',
                  'payout_paid','payout_failed',
                  'payout_paid_offplatform','payout_failed_offplatform'
                ) not null,
  amount_minor int unsigned not null,
  currency     char(3) not null,
  created_at   timestamp default current_timestamp,

  constraint fk_trail_payment
    foreign key (payment_id) references payment(payment_id)
    on update cascade on delete cascade,

  key idx_trail_payment (payment_id),
  key idx_trail_type (entry_type),

  constraint chk_trail_amount_pos check (amount_minor >= 0),
  constraint chk_trail_currency_len check (char_length(currency) = 3)
) engine=innodb default charset=utf8mb4;

-- possible off-platform payouts  (bank/other)
create table if not exists payout (
  payout_id     bigint unsigned primary key auto_increment,
  recipient_id  char(36) not null,
  amount_minor  int unsigned not null,
  currency      char(3) not null,
  method        enum('wire','ach','wise','other') not null default 'other',
  reference     varchar(100) null,
  status        enum('initiated','sent','failed','reconciled') not null default 'initiated',
  external_id   varchar(100) null,
  created_at    timestamp default current_timestamp,
  updated_at    timestamp default current_timestamp on update current_timestamp,

  constraint fk_payout_recipient
    foreign key (recipient_id) references recipient(recipient_id)
    on update cascade on delete restrict,

  constraint chk_payout_currency_len check (char_length(currency) = 3),
  constraint chk_payout_amount_pos check (amount_minor > 0)
) engine=innodb default charset=utf8mb4;


-- helpful secondary indexes
create index idx_trail_payment_created on transaction_trail(payment_id, created_at);
create index idx_payment_status_created on payment(status, created_at);

-- convenience view: donor + (optional) recipient
drop view if exists v_payments_enriched;
create view v_payments_enriched as
select
  p.payment_id,
  p.amount_minor,
  p.currency,
  p.status,
  p.stripe_payment_intent_id,
  p.stripe_checkout_id,
  p.created_at,
  d.fullname  as donor_name,
  d.email     as donor_email,
  r.full_name as recipient_name,
  r.email     as recipient_email
from payment p
join donor d on d.donor_id = p.donor_id
left join recipient r on r.recipient_id = p.recipient_id;

-- analytics friendly layer below (data warehouse populated via ETL from OLTP). WILL NOT BE DONE IF TIME BECOMES A CRUNCH

-- date dimension (used by facts for fast time-based slicing)
create table if not exists dim_date (
  date_key      int primary key,      -- yyyymmdd (e.g., 20251114)
  full_date     date not null,
  year          smallint not null,
  quarter       tinyint not null,
  month         tinyint not null,
  month_name    varchar(15) not null,
  day           tinyint not null,
  day_of_week   tinyint not null,     -- 1=Monday .. 7=Sunday
  week_of_year  tinyint not null
) engine=innodb default charset=utf8mb4;

-- donor dimension (snapshot for analytics; avoids joining OLTP tables for every query)
create table if not exists dim_donor (
  dim_donor_id  int unsigned primary key auto_increment,
  donor_id      char(36) not null,          -- natural key from OLTP
  email         varchar(255) not null,
  fullname      varchar(200) not null,
  country       varchar(2) null,
  first_donation_date_key int null,         -- FK to dim_date.date_key in ETL
  created_at    timestamp default current_timestamp,

  unique key uq_dim_donor_donor_id (donor_id)
) engine=innodb default charset=utf8mb4;

-- recipient dimension
create table if not exists dim_recipient (
  dim_recipient_id int unsigned primary key auto_increment,
  recipient_id     char(36) not null,       -- natural key from OLTP
  email            varchar(100) not null,
  full_name        varchar(100) not null,
  country          varchar(2) null,
  stripe_account_id varchar(64) null,
  created_at       timestamp default current_timestamp,

  unique key uq_dim_recipient_recipient_id (recipient_id)
) engine=innodb default charset=utf8mb4;

-- donation fact table (one row per successful payment, typically)
create table if not exists fact_donation (
  fact_donation_id   bigint unsigned primary key auto_increment,
  payment_id         bigint unsigned not null,  -- link back to OLTP payment
  dim_donor_id       int unsigned not null,
  dim_recipient_id   int unsigned null,
  donation_date_key  int not null,             -- from dim_date
  currency           char(3) not null,
  amount_minor       bigint unsigned not null,
  amount_minor_usd   bigint unsigned null,
  status             enum('pending','success','failed','refunded') not null,

  key idx_fact_donation_donor (dim_donor_id),
  key idx_fact_donation_recipient (dim_recipient_id),
  key idx_fact_donation_date (donation_date_key),
  key idx_fact_donation_status (status),

  constraint fk_fact_donation_payment
    foreign key (payment_id) references payment(payment_id)
      on update cascade on delete cascade,
  constraint fk_fact_donation_dim_donor
    foreign key (dim_donor_id) references dim_donor(dim_donor_id)
      on update cascade on delete restrict,
  constraint fk_fact_donation_dim_recipient
    foreign key (dim_recipient_id) references dim_recipient(dim_recipient_id)
      on update cascade on delete set null,
  constraint fk_fact_donation_dim_date
    foreign key (donation_date_key) references dim_date(date_key)
      on update cascade on delete restrict
) engine=innodb default charset=utf8mb4;

-- payout fact table (total funds out per payout event)
create table if not exists fact_payout (
  fact_payout_id     bigint unsigned primary key auto_increment,
  payout_id          bigint unsigned not null,   -- link back to OLTP payout
  dim_recipient_id   int unsigned not null,
  payout_date_key    int not null,
  currency           char(3) not null,
  amount_minor       bigint unsigned not null,
  method             enum('wire','ach','wise','other') not null,
  status             enum('initiated','sent','failed','reconciled') not null,

  key idx_fact_payout_recipient (dim_recipient_id),
  key idx_fact_payout_date (payout_date_key),
  key idx_fact_payout_status (status),

  constraint fk_fact_payout_payout
    foreign key (payout_id) references payout(payout_id)
      on update cascade on delete cascade,
  constraint fk_fact_payout_dim_recipient
    foreign key (dim_recipient_id) references dim_recipient(dim_recipient_id)
      on update cascade on delete restrict,
  constraint fk_fact_payout_dim_date
    foreign key (payout_date_key) references dim_date(date_key)
      on update cascade on delete restrict
) engine=innodb default charset=utf8mb4;

-- dividing stripe and payhere payments
alter table payment
  add column provider enum('stripe','payhere') not null default 'stripe';

alter table webhook_event
  add column provider enum('stripe','payhere') not null default 'stripe';
