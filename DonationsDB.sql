create database if not exists donationsdb
  default character set utf8mb4
  collate utf8mb4_unicode_ci;

use donationsdb;


create table if not exists donor (
  donor_id        char(36) primary key,
  fullname        varchar(200) not null,
  email           varchar(255) not null unique,
  country         varchar(2) null,
  public_opt_in   tinyint(1) not null default 0, -- donor can opt-in to show name publicly
  created_at      timestamp default current_timestamp,
  updated_at      timestamp default current_timestamp on update current_timestamp,
  key idx_donor_email (email),
  constraint chk_donor_country_len check (country is null or char_length(country) = 2)
) engine=innodb default charset=utf8mb4;

-- (connected accounts)
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

create table if not exists campaign (
  campaign_id  bigint unsigned primary key auto_increment,
  slug         varchar(100) not null unique,
  name         varchar(200) not null,
  currency     char(3) not null,
  is_active    tinyint(1) not null default 1,
  created_at   timestamp not null default current_timestamp,
  updated_at   timestamp default current_timestamp on update current_timestamp,
  constraint chk_campaign_currency_len check (char_length(currency) = 3)
) engine=innodb default charset=utf8mb4;

create table if not exists payment (
  payment_id               bigint unsigned primary key auto_increment,
  donor_id                 char(36) not null,
  recipient_id             char(36) null,
  campaign_id              bigint unsigned null,
  amount_minor             int unsigned not null,
  currency                 char(3) not null,
  status                   enum('pending','success','failed','refunded') not null default 'pending',
  stripe_payment_intent_id varchar(64) unique,
  stripe_checkout_id       varchar(64) null,
  amount_minor_usd         int unsigned null, -- optional normalized reporting
  created_at               timestamp default current_timestamp,
  updated_at               timestamp default current_timestamp on update current_timestamp,

  constraint fk_payment_donor
    foreign key (donor_id) references donor(donor_id)
    on update cascade on delete restrict,

  constraint fk_payment_recipient
    foreign key (recipient_id) references recipient(recipient_id)
    on update cascade on delete set null,

  constraint fk_payment_campaign
    foreign key (campaign_id) references campaign(campaign_id)
    on update cascade on delete set null,

  key idx_payment_donor (donor_id),
  key idx_payment_recipient (recipient_id),
  key idx_payment_campaign (campaign_id),
  key idx_payment_status (status),

  constraint chk_payment_amount_pos check (amount_minor > 0),
  constraint chk_payment_currency_len check (char_length(currency) = 3)
) engine=innodb default charset=utf8mb4;

-- (recurring payments)
create table if not exists subscription (
  subscription_id        bigint unsigned primary key auto_increment,
  donor_id               char(36) not null,
  campaign_id            bigint unsigned null,
  stripe_subscription_id varchar(64) not null unique,
  price_currency         char(3) not null,
  price_amount_minor     int unsigned not null,
  status                 enum('trial','active','past_due','canceled','unpaid') not null,
  started_at             timestamp default current_timestamp,
  updated_at             timestamp default current_timestamp on update current_timestamp,

  constraint fk_sub_donor
    foreign key (donor_id) references donor(donor_id)
    on update cascade on delete restrict,

  constraint fk_sub_campaign
    foreign key (campaign_id) references campaign(campaign_id)
    on update cascade on delete set null,

  key idx_sub_donor (donor_id),
  key idx_sub_campaign (campaign_id),
  key idx_sub_status (status),

  constraint chk_sub_currency_len check (char_length(price_currency) = 3),
  constraint chk_sub_amount_pos check (price_amount_minor > 0)
) engine=innodb default charset=utf8mb4;


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

-- transactions (audit trail per payment)
create table if not exists transaction_trail (
  entry_id     bigint unsigned primary key auto_increment,
  payment_id   bigint unsigned not null,
  entry_type   enum('intent_created','payment_succeeded','transfer_out','fee','refund','payout_paid','payout_failed') not null,
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

-- email events (receipts/notices)
create table if not exists email_event (
  email_event_id bigint unsigned primary key auto_increment,
  payment_id     bigint unsigned null,
  to_email       varchar(255) not null,
  subject        varchar(200) not null,
  status         enum('queued','sent','failed') not null default 'queued',
  provider       varchar(50) null,
  created_at     timestamp default current_timestamp,
  updated_at     timestamp default current_timestamp on update current_timestamp,

  constraint fk_email_payment
    foreign key (payment_id) references payment(payment_id)
    on update cascade on delete set null,

  key idx_email_payment (payment_id),
  key idx_email_status (status)
) engine=innodb default charset=utf8mb4;

-- indexes for easy lookup
create index idx_payment_checkout on payment(stripe_checkout_id);
create index idx_trail_payment_created on transaction_trail(payment_id, created_at);
create index idx_email_created on email_event(created_at);
