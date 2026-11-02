IF SCHEMA_ID('lineboard') IS NULL EXEC('CREATE SCHEMA lineboard');
IF OBJECT_ID('lineboard.Settings') IS NULL
BEGIN
 CREATE TABLE lineboard.Settings (id int PRIMARY KEY CHECK(id=1), cart_version bigint NOT NULL DEFAULT 0);
 INSERT lineboard.Settings(id) VALUES(1);
 CREATE SEQUENCE lineboard.BarcodeNumber AS bigint START WITH 900000000001 INCREMENT BY 1 MAXVALUE 999999999999 NO CYCLE;
 CREATE TABLE lineboard.Operations (
  id uniqueidentifier PRIMARY KEY, kind varchar(40) NOT NULL, request_hash varchar(64) NOT NULL,
  response nvarchar(max) NOT NULL, created_at datetime2 NOT NULL DEFAULT SYSUTCDATETIME()
 );
 CREATE TABLE lineboard.Units (
  id uniqueidentifier PRIMARY KEY, product_id uniqueidentifier NOT NULL, variant_id uniqueidentifier NOT NULL,
  sic_id int NOT NULL UNIQUE, barcode varchar(20) NOT NULL UNIQUE, category nvarchar(40) NOT NULL DEFAULT '', color nvarchar(40) NOT NULL,
  size nvarchar(40) NOT NULL, location nvarchar(80) NOT NULL, photo nvarchar(1000) NOT NULL,
  expected_quantity int NOT NULL CHECK(expected_quantity IN (0,1)), revision bigint NOT NULL DEFAULT 1,
  created_at datetime2 NOT NULL DEFAULT SYSUTCDATETIME(), updated_at datetime2 NOT NULL DEFAULT SYSUTCDATETIME()
 );
 CREATE TABLE lineboard.Cart (unit_id uniqueidentifier PRIMARY KEY REFERENCES lineboard.Units(id), added_at datetime2 NOT NULL DEFAULT SYSUTCDATETIME());
 CREATE TABLE lineboard.Movements (
  id bigint IDENTITY PRIMARY KEY, operation_id uniqueidentifier NOT NULL, unit_id uniqueidentifier NOT NULL REFERENCES lineboard.Units(id),
  delta int NOT NULL CHECK(delta IN (-1,1)), reason varchar(30) NOT NULL, sic_document_id int NULL,
  created_at datetime2 NOT NULL DEFAULT SYSUTCDATETIME()
 );
 CREATE TABLE lineboard.Sales (
  id uniqueidentifier PRIMARY KEY, operation_id uniqueidentifier NOT NULL UNIQUE,
  sic_id int NOT NULL UNIQUE, payment varchar(20) NOT NULL, total decimal(19,4) NOT NULL,
  fiscal_status varchar(30) NOT NULL DEFAULT 'not_requested', created_at datetime2 NOT NULL DEFAULT SYSUTCDATETIME()
 );
 CREATE TABLE lineboard.Outbox (
  id bigint IDENTITY PRIMARY KEY, event_id uniqueidentifier NOT NULL UNIQUE, kind varchar(40) NOT NULL,
  payload nvarchar(max) NOT NULL, state varchar(20) NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','sent','conflict')),
  attempts int NOT NULL DEFAULT 0, last_error nvarchar(500) NULL, created_at datetime2 NOT NULL DEFAULT SYSUTCDATETIME(), sent_at datetime2 NULL
 );
 CREATE TABLE lineboard.UnitEdits (
  id bigint IDENTITY PRIMARY KEY, operation_id uniqueidentifier NOT NULL, unit_id uniqueidentifier NOT NULL,
  before_json nvarchar(max) NOT NULL, after_json nvarchar(max) NOT NULL, created_at datetime2 NOT NULL DEFAULT SYSUTCDATETIME()
 );
 CREATE TABLE lineboard.Devices (
  token_hash varchar(64) PRIMARY KEY, name nvarchar(80) NOT NULL, created_at datetime2 NOT NULL DEFAULT SYSUTCDATETIME(), revoked bit NOT NULL DEFAULT 0
 );
END;

IF OBJECT_ID('lineboard.Units') IS NOT NULL AND COL_LENGTH('lineboard.Units','category') IS NULL
  ALTER TABLE lineboard.Units ADD category nvarchar(40) NOT NULL CONSTRAINT DF_lineboard_Units_category DEFAULT '' WITH VALUES;

IF COL_LENGTH('lineboard.Settings','cloud_cart_version') IS NULL
  ALTER TABLE lineboard.Settings ADD cloud_cart_version bigint NOT NULL CONSTRAINT DF_lineboard_cloud_cart_version DEFAULT -1 WITH VALUES;
