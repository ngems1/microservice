-- Week 3 schema for the boutique database (RDS MySQL 8.4).
-- products: read by productcatalogservice (cached in Redis)
-- orders:   written by checkoutservice (PENDING), updated by the order-status Lambda

CREATE TABLE IF NOT EXISTS products (
  id              VARCHAR(32)  NOT NULL PRIMARY KEY,
  name            VARCHAR(255) NOT NULL,
  description     TEXT         NOT NULL,
  picture         VARCHAR(255) NOT NULL,
  price_currency  CHAR(3)      NOT NULL,
  price_units     BIGINT       NOT NULL,
  price_nanos     INT          NOT NULL,
  categories      VARCHAR(255) NOT NULL DEFAULT ''   -- comma separated
);

CREATE TABLE IF NOT EXISTS orders (
  order_id              VARCHAR(64)  NOT NULL PRIMARY KEY,
  email                 VARCHAR(255) NOT NULL,
  status                VARCHAR(16)  NOT NULL DEFAULT 'PENDING',  -- PENDING | CONFIRMED | FAILED
  status_reason         VARCHAR(64)  NOT NULL DEFAULT '',
  currency              CHAR(3)      NOT NULL,
  total_units           BIGINT       NOT NULL,
  total_nanos           INT          NOT NULL,
  items                 JSON         NOT NULL,                    -- [{"productId": "...", "quantity": 1}]
  shipping_tracking_id  VARCHAR(64)  NOT NULL DEFAULT '',
  created_at            TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at            TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  INDEX idx_orders_status (status)
);
