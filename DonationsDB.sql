-- schema (stripe checkout intake + webhook-first)

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
  key idx_donor_email (email),
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

-- subscriptions (will implement later)
create table if not exists subscription (
  subscription_id        bigint unsigned primary key auto_increment,
  donor_id               char(36) not null,
  stripe_subscription_id varchar(64) not null unique,
  price_currency         char(3) not null,
  price_amount_minor     int unsigned not null,
  status                 enum('trial','active','past_due','canceled','unpaid') not null,
  started_at             timestamp default current_timestamp,
  updated_at             timestamp default current_timestamp on update current_timestamp,

  constraint fk_sub_donor
    foreign key (donor_id) references donor(donor_id)
    on update cascade on delete restrict,

  key idx_sub_donor (donor_id),
  key idx_sub_status (status),

  constraint chk_sub_currency_len check (char_length(price_currency) = 3),
  constraint chk_sub_amount_pos check (price_amount_minor > 0)
) engine=innodb default charset=utf8mb4;

-- raw stripe events; unique(event_id) = idempotency guard
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

-- off-platform payouts you execute (bank/wise/other)
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

-- optional: map multiple incoming payments to one payout
create table if not exists payout_payment (
  payout_id   bigint unsigned not null,
  payment_id  bigint unsigned not null,
  primary key (payout_id, payment_id),
  constraint fk_pp_payout  foreign key (payout_id)  references payout(payout_id)
    on update cascade on delete cascade,
  constraint fk_pp_payment foreign key (payment_id) references payment(payment_id)
    on update cascade on delete cascade
) engine=innodb default charset=utf8mb4;

-- helpful secondary indexes
create index idx_trail_payment_created on transaction_trail(payment_id, created_at);
create index idx_email_created on email_event(created_at);

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

-- sanity queries after a test checkout + webhook
select webhook_event_id, stripe_event_id, type, received_at
from webhook_event
order by webhook_event_id desc
limit 5;

select donor_id, fullname, email, created_at
from donor
order by created_at desc
limit 5;

select payment_id, donor_id, amount_minor, currency, status,
       stripe_payment_intent_id, stripe_checkout_id, created_at
from payment
order by payment_id desc
limit 5;

select entry_id, payment_id, entry_type, amount_minor, currency, created_at
from transaction_trail
order by entry_id desc
limit 5;

select * from v_payments_enriched order by payment_id desc limit 5;

