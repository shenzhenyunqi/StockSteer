-- CreateEnum
CREATE TYPE "Channel" AS ENUM ('DTC', 'FBA', 'FBM');

-- CreateEnum
CREATE TYPE "InvKind" AS ENUM ('snapshot', 'delta', 'correction');

-- CreateEnum
CREATE TYPE "InvState" AS ENUM ('sellable', 'reserved', 'inbound');

-- CreateEnum
CREATE TYPE "SalesKind" AS ENUM ('sale', 'cancellation');

-- CreateEnum
CREATE TYPE "Source" AS ENUM ('shopify_webhook', 'shopify_bulk', 'amazon_report', 'reconciliation', 'csv_import');

-- CreateEnum
CREATE TYPE "MappingMethod" AS ENUM ('EXACT', 'NORMALIZED', 'FUZZY');

-- CreateEnum
CREATE TYPE "MappingStatus" AS ENUM ('pending', 'confirmed', 'rejected');

-- CreateEnum
CREATE TYPE "CardType" AS ENUM ('MOVE_STOCK', 'MCF_POOL', 'SHARED_POOL', 'STOCKOUT_ETA');

-- CreateEnum
CREATE TYPE "CardStatus" AS ENUM ('active', 'adopted', 'ignored', 'superseded', 'withdrawn');

-- CreateEnum
CREATE TYPE "FeedbackAction" AS ENUM ('adopted', 'ignored', 'adjusted');

-- CreateEnum
CREATE TYPE "Plan" AS ENUM ('free');

-- CreateEnum
CREATE TYPE "Provider" AS ENUM ('shopify', 'amazon');

-- CreateEnum
CREATE TYPE "PoolKind" AS ENUM ('shared', 'separate');

-- CreateEnum
CREATE TYPE "CogsOverrideSource" AS ENUM ('override', 'csv');

-- CreateEnum
CREATE TYPE "VelocityWeighting" AS ENUM ('even', 'recent');

-- CreateEnum
CREATE TYPE "MovePriority" AS ENUM ('margin_first', 'cover_first');

-- CreateEnum
CREATE TYPE "PromoScope" AS ENUM ('all_products', 'selected_products');

-- CreateEnum
CREATE TYPE "ReconVerdict" AS ENUM ('match', 'ledger_wins', 'platform_wins');

-- CreateEnum
CREATE TYPE "WatchdogSource" AS ENUM ('shopify_webhook', 'shopify_bulk', 'amazon_notifications', 'amazon_inventory_planning', 'amazon_all_orders', 'amazon_merchant_listings', 'amazon_fba_fees', 'amazon_shipments');

-- CreateEnum
CREATE TYPE "EmailSendStatus" AS ENUM ('sent', 'failed', 'skipped');

-- CreateTable
CREATE TABLE "tenants" (
    "id" TEXT NOT NULL,
    "shopify_domain" TEXT NOT NULL,
    "timezone" TEXT NOT NULL,
    "plan" "Plan" NOT NULL DEFAULT 'free',
    "backfill_object_count" INTEGER,
    "uninstalled_at" TIMESTAMPTZ(3),
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "tenants_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "auth_tokens" (
    "id" TEXT NOT NULL,
    "tenant_id" TEXT NOT NULL,
    "provider" "Provider" NOT NULL,
    "ciphertext" TEXT NOT NULL,
    "key_version" INTEGER NOT NULL,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "auth_tokens_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "products" (
    "id" TEXT NOT NULL,
    "tenant_id" TEXT NOT NULL,
    "display_sku" TEXT NOT NULL,
    "title" TEXT NOT NULL,
    "cogs_synced" DECIMAL(12,2),
    "paused" BOOLEAN NOT NULL DEFAULT false,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "products_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "product_overrides" (
    "id" TEXT NOT NULL,
    "tenant_id" TEXT NOT NULL,
    "product_id" TEXT NOT NULL,
    "cover_days" INTEGER,
    "safety_days" INTEGER,
    "lead_days" INTEGER,
    "case_pack" INTEGER,
    "cogs" DECIMAL(12,2),
    "cogs_source" "CogsOverrideSource",
    "cogs_updated_at" TIMESTAMPTZ(3),
    "pool" "PoolKind",
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "product_overrides_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "channel_listings" (
    "id" TEXT NOT NULL,
    "tenant_id" TEXT NOT NULL,
    "product_id" TEXT NOT NULL,
    "channel" "Channel" NOT NULL,
    "external_id" TEXT NOT NULL,
    "inventory_item_id" TEXT,
    "price" DECIMAL(12,2),
    "listed" BOOLEAN NOT NULL DEFAULT true,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "channel_listings_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "sku_mappings" (
    "id" TEXT NOT NULL,
    "tenant_id" TEXT NOT NULL,
    "shopify_listing_id" TEXT NOT NULL,
    "amazon_listing_id" TEXT NOT NULL,
    "method" "MappingMethod" NOT NULL,
    "confidence" DECIMAL(5,4),
    "status" "MappingStatus" NOT NULL DEFAULT 'pending',
    "decided_by" TEXT,
    "decided_at" TIMESTAMPTZ(3),
    "decided_session" TEXT,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "sku_mappings_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "inventory_events" (
    "id" TEXT NOT NULL,
    "tenant_id" TEXT NOT NULL,
    "product_id" TEXT NOT NULL,
    "channel" "Channel" NOT NULL,
    "kind" "InvKind" NOT NULL,
    "state" "InvState" NOT NULL,
    "qty" INTEGER NOT NULL,
    "source" "Source" NOT NULL,
    "source_ref" TEXT NOT NULL,
    "occurred_at" TIMESTAMPTZ(3) NOT NULL,
    "recorded_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "inventory_events_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "sales_events" (
    "id" TEXT NOT NULL,
    "tenant_id" TEXT NOT NULL,
    "product_id" TEXT NOT NULL,
    "channel" "Channel" NOT NULL,
    "kind" "SalesKind" NOT NULL,
    "qty" INTEGER NOT NULL,
    "order_ref" TEXT NOT NULL,
    "excluded_reason" TEXT,
    "source" "Source" NOT NULL,
    "source_ref" TEXT NOT NULL,
    "occurred_at" TIMESTAMPTZ(3) NOT NULL,
    "recorded_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "sales_events_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "stockout_observations" (
    "id" TEXT NOT NULL,
    "tenant_id" TEXT NOT NULL,
    "product_id" TEXT NOT NULL,
    "channel" "Channel" NOT NULL,
    "date" DATE NOT NULL,
    "recorded_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "stockout_observations_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "stock_projection" (
    "tenant_id" TEXT NOT NULL,
    "product_id" TEXT NOT NULL,
    "channel" "Channel" NOT NULL,
    "state" "InvState" NOT NULL,
    "qty" INTEGER NOT NULL,
    "as_of" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "stock_projection_pkey" PRIMARY KEY ("tenant_id","product_id","channel","state")
);

-- CreateTable
CREATE TABLE "daily_units" (
    "tenant_id" TEXT NOT NULL,
    "product_id" TEXT NOT NULL,
    "channel" "Channel" NOT NULL,
    "date" DATE NOT NULL,
    "units" INTEGER NOT NULL,

    CONSTRAINT "daily_units_pkey" PRIMARY KEY ("tenant_id","product_id","channel","date")
);

-- CreateTable
CREATE TABLE "shopify_location_levels" (
    "id" TEXT NOT NULL,
    "tenant_id" TEXT NOT NULL,
    "location_id" TEXT NOT NULL,
    "inventory_item_id" TEXT NOT NULL,
    "available" INTEGER,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "shopify_location_levels_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "reconciliation_runs" (
    "id" TEXT NOT NULL,
    "tenant_id" TEXT NOT NULL,
    "run_key" TEXT NOT NULL,
    "started_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "finished_at" TIMESTAMPTZ(3),

    CONSTRAINT "reconciliation_runs_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "reconciliation_rows" (
    "id" TEXT NOT NULL,
    "tenant_id" TEXT NOT NULL,
    "run_id" TEXT NOT NULL,
    "product_id" TEXT NOT NULL,
    "ledger_qty" INTEGER NOT NULL,
    "shopify_qty" INTEGER,
    "amazon_qty" INTEGER,
    "delta_qty" INTEGER NOT NULL,
    "within_tolerance" BOOLEAN NOT NULL,
    "verdict" "ReconVerdict" NOT NULL,
    "reason" TEXT,
    "correction_event_id" TEXT,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "reconciliation_rows_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "params" (
    "tenant_id" TEXT NOT NULL,
    "cover_days" INTEGER NOT NULL DEFAULT 35,
    "safety_days" INTEGER NOT NULL DEFAULT 14,
    "lead_days" INTEGER NOT NULL DEFAULT 7,
    "ceiling_days" INTEGER NOT NULL DEFAULT 60,
    "velocity_window_days" INTEGER NOT NULL DEFAULT 90,
    "velocity_weighting" "VelocityWeighting" NOT NULL DEFAULT 'even',
    "exclude_stockout_days" BOOLEAN NOT NULL DEFAULT true,
    "apply_promo" BOOLEAN NOT NULL DEFAULT true,
    "round_up_to_case" BOOLEAN NOT NULL DEFAULT true,
    "min_move_qty" INTEGER NOT NULL DEFAULT 24,
    "move_priority" "MovePriority" NOT NULL DEFAULT 'margin_first',
    "self_ship_cost_per_order" DECIMAL(12,2) NOT NULL DEFAULT 6.90,
    "mcf_enabled" BOOLEAN NOT NULL DEFAULT true,
    "mcf_fee_per_order" DECIMAL(12,2) NOT NULL DEFAULT 5.87,
    "removal_fee_per_unit" DECIMAL(12,2) NOT NULL DEFAULT 0.97,
    "alert_lead_days" INTEGER NOT NULL DEFAULT 10,
    "ipi_score" INTEGER,
    "inbound_limit_remaining" INTEGER,
    "ipi_entered_at" TIMESTAMPTZ(3),
    "limit_entered_at" TIMESTAMPTZ(3),
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "params_pkey" PRIMARY KEY ("tenant_id")
);

-- CreateTable
CREATE TABLE "promo_events" (
    "id" TEXT NOT NULL,
    "tenant_id" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "channel" "Channel" NOT NULL,
    "starts_on" DATE NOT NULL,
    "ends_on" DATE NOT NULL,
    "multiplier" DECIMAL(6,3) NOT NULL,
    "scope" "PromoScope" NOT NULL,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "promo_events_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "promo_event_products" (
    "id" TEXT NOT NULL,
    "tenant_id" TEXT NOT NULL,
    "promo_event_id" TEXT NOT NULL,
    "product_id" TEXT NOT NULL,

    CONSTRAINT "promo_event_products_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "engine_runs" (
    "id" TEXT NOT NULL,
    "tenant_id" TEXT NOT NULL,
    "date" DATE NOT NULL,
    "card_count" INTEGER NOT NULL,
    "duration_ms" INTEGER NOT NULL,
    "gates" JSONB NOT NULL,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "engine_runs_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "recommendation_cards" (
    "id" TEXT NOT NULL,
    "tenant_id" TEXT NOT NULL,
    "run_id" TEXT NOT NULL,
    "product_id" TEXT NOT NULL,
    "card_type" "CardType" NOT NULL,
    "dest_channel" "Channel",
    "qty" INTEGER,
    "ship_by" DATE,
    "explain" JSONB NOT NULL,
    "status" "CardStatus" NOT NULL DEFAULT 'active',
    "related_card_id" TEXT,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "recommendation_cards_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "recommendation_feedback" (
    "id" TEXT NOT NULL,
    "tenant_id" TEXT NOT NULL,
    "rec_id" TEXT NOT NULL,
    "action" "FeedbackAction" NOT NULL,
    "adjusted_qty" INTEGER,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "recommendation_feedback_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "email_recipients" (
    "id" TEXT NOT NULL,
    "tenant_id" TEXT NOT NULL,
    "email" TEXT NOT NULL,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "email_recipients_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "email_sends" (
    "id" TEXT NOT NULL,
    "tenant_id" TEXT NOT NULL,
    "date" DATE NOT NULL,
    "status" "EmailSendStatus" NOT NULL,
    "recipient_count" INTEGER NOT NULL,
    "error" TEXT,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "email_sends_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "source_status" (
    "id" TEXT NOT NULL,
    "tenant_id" TEXT NOT NULL,
    "source" "WatchdogSource" NOT NULL,
    "last_ok_at" TIMESTAMPTZ(3),
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "source_status_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "dead_letters" (
    "id" TEXT NOT NULL,
    "tenant_id" TEXT,
    "source" "Source" NOT NULL,
    "payload" JSONB NOT NULL,
    "reason" TEXT NOT NULL,
    "replayed_at" TIMESTAMPTZ(3),
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "dead_letters_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "tenants_shopify_domain_key" ON "tenants"("shopify_domain");

-- CreateIndex
CREATE UNIQUE INDEX "auth_tokens_tenant_id_provider_key" ON "auth_tokens"("tenant_id", "provider");

-- CreateIndex
CREATE INDEX "products_tenant_id_display_sku_idx" ON "products"("tenant_id", "display_sku");

-- CreateIndex
CREATE UNIQUE INDEX "product_overrides_product_id_key" ON "product_overrides"("product_id");

-- CreateIndex
CREATE INDEX "channel_listings_tenant_id_inventory_item_id_idx" ON "channel_listings"("tenant_id", "inventory_item_id");

-- CreateIndex
CREATE UNIQUE INDEX "channel_listings_tenant_id_channel_external_id_key" ON "channel_listings"("tenant_id", "channel", "external_id");

-- CreateIndex
CREATE UNIQUE INDEX "sku_mappings_tenant_id_shopify_listing_id_amazon_listing_id_key" ON "sku_mappings"("tenant_id", "shopify_listing_id", "amazon_listing_id");

-- CreateIndex
CREATE INDEX "inventory_events_tenant_id_product_id_channel_occurred_at_idx" ON "inventory_events"("tenant_id", "product_id", "channel", "occurred_at");

-- CreateIndex
CREATE UNIQUE INDEX "inventory_events_tenant_id_source_source_ref_key" ON "inventory_events"("tenant_id", "source", "source_ref");

-- CreateIndex
CREATE INDEX "sales_events_tenant_id_product_id_channel_occurred_at_idx" ON "sales_events"("tenant_id", "product_id", "channel", "occurred_at");

-- CreateIndex
CREATE UNIQUE INDEX "sales_events_tenant_id_source_source_ref_key" ON "sales_events"("tenant_id", "source", "source_ref");

-- CreateIndex
CREATE UNIQUE INDEX "stockout_observations_tenant_id_product_id_channel_date_key" ON "stockout_observations"("tenant_id", "product_id", "channel", "date");

-- CreateIndex
CREATE UNIQUE INDEX "shopify_location_levels_tenant_id_location_id_inventory_ite_key" ON "shopify_location_levels"("tenant_id", "location_id", "inventory_item_id");

-- CreateIndex
CREATE UNIQUE INDEX "reconciliation_runs_tenant_id_run_key_key" ON "reconciliation_runs"("tenant_id", "run_key");

-- CreateIndex
CREATE INDEX "reconciliation_rows_tenant_id_run_id_idx" ON "reconciliation_rows"("tenant_id", "run_id");

-- CreateIndex
CREATE UNIQUE INDEX "promo_event_products_promo_event_id_product_id_key" ON "promo_event_products"("promo_event_id", "product_id");

-- CreateIndex
CREATE UNIQUE INDEX "engine_runs_tenant_id_date_key" ON "engine_runs"("tenant_id", "date");

-- CreateIndex
CREATE UNIQUE INDEX "rec_cards_active_slot_uq" ON "recommendation_cards"("tenant_id", "product_id", "card_type", "dest_channel") WHERE (status = 'active' AND dest_channel IS NOT NULL);

-- CreateIndex
CREATE UNIQUE INDEX "rec_cards_active_slot_nochannel_uq" ON "recommendation_cards"("tenant_id", "product_id", "card_type") WHERE (status = 'active' AND dest_channel IS NULL);

-- CreateIndex
CREATE UNIQUE INDEX "recommendation_feedback_rec_id_key" ON "recommendation_feedback"("rec_id");

-- CreateIndex
CREATE UNIQUE INDEX "email_recipients_tenant_id_email_key" ON "email_recipients"("tenant_id", "email");

-- CreateIndex
CREATE UNIQUE INDEX "email_sends_tenant_id_date_key" ON "email_sends"("tenant_id", "date");

-- CreateIndex
CREATE UNIQUE INDEX "source_status_tenant_id_source_key" ON "source_status"("tenant_id", "source");

-- CreateIndex
CREATE INDEX "dead_letters_tenant_id_source_idx" ON "dead_letters"("tenant_id", "source");

-- AddForeignKey
ALTER TABLE "auth_tokens" ADD CONSTRAINT "auth_tokens_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "tenants"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "products" ADD CONSTRAINT "products_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "tenants"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "product_overrides" ADD CONSTRAINT "product_overrides_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "tenants"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "product_overrides" ADD CONSTRAINT "product_overrides_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "products"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "channel_listings" ADD CONSTRAINT "channel_listings_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "tenants"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "channel_listings" ADD CONSTRAINT "channel_listings_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "products"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "sku_mappings" ADD CONSTRAINT "sku_mappings_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "tenants"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "sku_mappings" ADD CONSTRAINT "sku_mappings_shopify_listing_id_fkey" FOREIGN KEY ("shopify_listing_id") REFERENCES "channel_listings"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "sku_mappings" ADD CONSTRAINT "sku_mappings_amazon_listing_id_fkey" FOREIGN KEY ("amazon_listing_id") REFERENCES "channel_listings"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "inventory_events" ADD CONSTRAINT "inventory_events_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "tenants"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "inventory_events" ADD CONSTRAINT "inventory_events_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "products"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "sales_events" ADD CONSTRAINT "sales_events_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "tenants"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "sales_events" ADD CONSTRAINT "sales_events_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "products"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "stockout_observations" ADD CONSTRAINT "stockout_observations_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "tenants"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "stockout_observations" ADD CONSTRAINT "stockout_observations_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "products"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "stock_projection" ADD CONSTRAINT "stock_projection_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "tenants"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "stock_projection" ADD CONSTRAINT "stock_projection_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "products"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "daily_units" ADD CONSTRAINT "daily_units_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "tenants"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "daily_units" ADD CONSTRAINT "daily_units_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "products"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "shopify_location_levels" ADD CONSTRAINT "shopify_location_levels_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "tenants"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "reconciliation_runs" ADD CONSTRAINT "reconciliation_runs_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "tenants"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "reconciliation_rows" ADD CONSTRAINT "reconciliation_rows_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "tenants"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "reconciliation_rows" ADD CONSTRAINT "reconciliation_rows_run_id_fkey" FOREIGN KEY ("run_id") REFERENCES "reconciliation_runs"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "reconciliation_rows" ADD CONSTRAINT "reconciliation_rows_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "products"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "reconciliation_rows" ADD CONSTRAINT "reconciliation_rows_correction_event_id_fkey" FOREIGN KEY ("correction_event_id") REFERENCES "inventory_events"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "params" ADD CONSTRAINT "params_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "tenants"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "promo_events" ADD CONSTRAINT "promo_events_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "tenants"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "promo_event_products" ADD CONSTRAINT "promo_event_products_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "tenants"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "promo_event_products" ADD CONSTRAINT "promo_event_products_promo_event_id_fkey" FOREIGN KEY ("promo_event_id") REFERENCES "promo_events"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "promo_event_products" ADD CONSTRAINT "promo_event_products_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "products"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "engine_runs" ADD CONSTRAINT "engine_runs_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "tenants"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "recommendation_cards" ADD CONSTRAINT "recommendation_cards_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "tenants"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "recommendation_cards" ADD CONSTRAINT "recommendation_cards_run_id_fkey" FOREIGN KEY ("run_id") REFERENCES "engine_runs"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "recommendation_cards" ADD CONSTRAINT "recommendation_cards_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "products"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "recommendation_cards" ADD CONSTRAINT "recommendation_cards_related_card_id_fkey" FOREIGN KEY ("related_card_id") REFERENCES "recommendation_cards"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "recommendation_feedback" ADD CONSTRAINT "recommendation_feedback_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "tenants"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "recommendation_feedback" ADD CONSTRAINT "recommendation_feedback_rec_id_fkey" FOREIGN KEY ("rec_id") REFERENCES "recommendation_cards"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "email_recipients" ADD CONSTRAINT "email_recipients_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "tenants"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "email_sends" ADD CONSTRAINT "email_sends_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "tenants"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "source_status" ADD CONSTRAINT "source_status_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "tenants"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "dead_letters" ADD CONSTRAINT "dead_letters_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "tenants"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- ============================================================================
-- 权限(p0 §0 fail-closed 的落地;T3 spec「每条都在 migration 里」)
-- ============================================================================
--
-- 上面这一整批表是 migrator 建的,所以 db/roles.sql 的
--   ALTER DEFAULT PRIVILEGES FOR ROLE migrator IN SCHEMA public
--     GRANT SELECT, INSERT ON TABLES TO app_runtime
-- 已经给了 app_runtime **SELECT + INSERT**,一条都不用在这里写。
-- 本段只做三件默认权限**故意不做**的事:
--   ① 可变表显式放开 UPDATE / DELETE —— 漏写的表当场写不动,这是设计不是 bug;
--   ② 三张事件表**什么都不写** —— 它们保持 append-only,正因为这里没有它们;
--   ③ app_purger 只在三张事件表上拿 SELECT + DELETE,别处一无所有(拍板点⑥)。
--
-- 刻意逐表写全、不用 `GRANT ALL` 也不用 DO 循环:
--   · `GRANT ALL` 会把 TRUNCATE / REFERENCES / TRIGGER 一并带进来 —— TRUNCATE
--     一条语句抹平账本,TRIGGER 让非 owner 也能挂 `BEFORE INSERT ... RETURN NULL`
--     把写静默丢掉,而只查 UPDATE/DELETE 的断言看不见这两样(db/verify-roles.sh
--     的全局断言正是为此而设,它会当场响)。
--   · 循环放权等于把"哪张表可变"这个判断交给运行时,新表会自动获得权限 ——
--     fail-closed 的全部价值就是新表**不**自动获得权限。

-- ① 可变表:20 张。
GRANT UPDATE, DELETE ON "tenants"                 TO app_runtime;
GRANT UPDATE, DELETE ON "auth_tokens"             TO app_runtime;
GRANT UPDATE, DELETE ON "products"                TO app_runtime;
GRANT UPDATE, DELETE ON "product_overrides"       TO app_runtime;
GRANT UPDATE, DELETE ON "channel_listings"        TO app_runtime;
GRANT UPDATE, DELETE ON "sku_mappings"            TO app_runtime;
GRANT UPDATE, DELETE ON "params"                  TO app_runtime;
GRANT UPDATE, DELETE ON "promo_events"            TO app_runtime;
GRANT UPDATE, DELETE ON "promo_event_products"    TO app_runtime;
GRANT UPDATE, DELETE ON "stock_projection"        TO app_runtime;
GRANT UPDATE, DELETE ON "daily_units"             TO app_runtime;
GRANT UPDATE, DELETE ON "shopify_location_levels" TO app_runtime;
GRANT UPDATE, DELETE ON "reconciliation_runs"     TO app_runtime;
GRANT UPDATE, DELETE ON "reconciliation_rows"     TO app_runtime;
GRANT UPDATE, DELETE ON "engine_runs"             TO app_runtime;
GRANT UPDATE, DELETE ON "recommendation_feedback" TO app_runtime;
GRANT UPDATE, DELETE ON "email_recipients"        TO app_runtime;
GRANT UPDATE, DELETE ON "email_sends"             TO app_runtime;
GRANT UPDATE, DELETE ON "source_status"           TO app_runtime;
GRANT UPDATE, DELETE ON "dead_letters"            TO app_runtime;

-- ①b recommendation_cards 是第 21 张可变表,但只可变**一列**。
-- 08 §4:「卡行不可变,自带快照」「CardRepo 只有 append + 状态迁移,无字段 UPDATE」。
-- 列级 UPDATE 把这句话下到 DB:改 qty / explain / ship_by 当场 42501。
-- DELETE 仍要给 —— 30 天物理删除要清掉整个租户,而 app_purger 只管三张事件表。
-- 连带纪律:本表在 schema.prisma 里**不能有 @updatedAt**,否则 Prisma 每次 update
-- 都会顺手写那一列,状态迁移会全部 42501。
GRANT UPDATE ("status") ON "recommendation_cards" TO app_runtime;
GRANT DELETE            ON "recommendation_cards" TO app_runtime;

-- ② 三张事件表:此处**故意留白**。
--    inventory_events / sales_events / stockout_observations 只有默认的 SELECT+INSERT。
--    db/verify-roles.sh 里那三条「T3 建表当天自动生效」的断言从今天起不再 SKIP。

-- ③ app_purger(拍板点⑥):全部权力就是下面这三句。
GRANT SELECT, DELETE ON "inventory_events"       TO app_purger;
GRANT SELECT, DELETE ON "sales_events"           TO app_purger;
GRANT SELECT, DELETE ON "stockout_observations"  TO app_purger;

-- ④ _prisma_migrations:app_runtime 不该碰迁移账本(默认权限给了它 SELECT+INSERT,
--    等于让运行时身份能伪造迁移记录)。
--    **不能无条件写**:该表不存在于 shadow database(schema engine 只在真实库里
--    create_migrations_table),裸写会让此后每次 `migrate dev` 撞 P3006。
--    包一层 to_regclass 守卫 —— 真实库里生效,shadow 里静默跳过(T3 spec 给的退路)。
DO $$
BEGIN
  IF to_regclass('public._prisma_migrations') IS NOT NULL THEN
    REVOKE ALL ON TABLE public._prisma_migrations FROM app_runtime, app_purger;
  END IF;
END
$$;
