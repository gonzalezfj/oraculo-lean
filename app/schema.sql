DROP TABLE IF EXISTS redemptions;
DROP TABLE IF EXISTS cards;

CREATE TABLE cards (
  id      INTEGER PRIMARY KEY,
  status  TEXT    NOT NULL CHECK (status IN ('available', 'sold', 'expired')),
  balance INTEGER NOT NULL CHECK (balance >= 0)
);

CREATE TABLE redemptions (
  id          INTEGER PRIMARY KEY,
  card_id     INTEGER NOT NULL REFERENCES cards (id),
  amount      INTEGER NOT NULL CHECK (amount > 0),
  reversed_at TEXT
);
