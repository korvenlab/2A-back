import { createHash, createHmac, randomUUID } from "node:crypto";
import { supabaseAdmin } from "./supabase/admin-client.js";

export type DashboardEventType =
  | "user.created"
  | "user.first_login"
  | "session.started"
  | "payment.succeeded"
  | "payment.failed"
  | "subscription.changed";

export type DashboardEvent = {
  event_id: string;
  event_type: DashboardEventType;
  occurred_at: string;
  product: "2avendas";
  external_user_id: string;
  organization_id?: string;
  email?: string;
  payload: Record<string, unknown>;
};

type OutboxRow = {
  id: string;
  event: DashboardEvent;
  attempts: number;
};

const PRODUCT = "2avendas";
const DEFAULT_TIMEOUT_MS = 4_000;
const DEFAULT_RETRIES = 2;
let draining = false;
let worker: NodeJS.Timeout | undefined;

function config(): { url: string; secret: string; timeoutMs: number; retries: number } | null {
  const url = process.env.DASHBOARD_INGEST_URL?.trim();
  const secret = process.env.TWO_AVENDAS_DASHBOARD_INGEST_SECRET?.trim();
  if (!url || !secret) return null;
  return {
    url,
    secret,
    timeoutMs: Math.max(250, Number(process.env.DASHBOARD_INGEST_TIMEOUT_MS) || DEFAULT_TIMEOUT_MS),
    retries: Math.max(0, Number(process.env.DASHBOARD_INGEST_RETRIES) || DEFAULT_RETRIES),
  };
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function deliver(event: DashboardEvent): Promise<void> {
  const cfg = config();
  if (!cfg) return;
  const rawBody = JSON.stringify(event);

  let lastError: unknown;
  for (let attempt = 0; attempt <= cfg.retries; attempt++) {
    const timestamp = Math.floor(Date.now() / 1000).toString();
    const signature = createHmac("sha256", cfg.secret)
      .update(`${timestamp}.${rawBody}`)
      .digest("hex");
    try {
      const response = await fetch(cfg.url, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-korven-product": PRODUCT,
          "x-korven-timestamp": timestamp,
          "x-korven-signature": signature,
        },
        body: rawBody,
        signal: AbortSignal.timeout(cfg.timeoutMs),
      });
      if (response.ok || response.status === 409) return;
      if (response.status < 500 && response.status !== 408 && response.status !== 429) {
        throw new Error(`Dashboard ingest rejected event (${response.status}).`);
      }
      lastError = new Error(`Dashboard ingest unavailable (${response.status}).`);
    } catch (error) {
      lastError = error;
    }
    if (attempt < cfg.retries) await delay(200 * 2 ** attempt);
  }
  throw lastError instanceof Error ? lastError : new Error("Dashboard ingest failed.");
}

export function createDashboardEvent(
  eventType: DashboardEventType,
  input: {
    externalUserId: string;
    organizationId?: string | null;
    email?: string | null;
    payload?: Record<string, unknown>;
    eventId?: string;
    occurredAt?: string;
  },
): DashboardEvent {
  return {
    event_id: input.eventId ?? randomUUID(),
    event_type: eventType,
    occurred_at: input.occurredAt ?? new Date().toISOString(),
    product: PRODUCT,
    external_user_id: input.externalUserId,
    ...(input.organizationId ? { organization_id: input.organizationId } : {}),
    ...(input.email ? { email: input.email } : {}),
    payload: input.payload ?? {},
  };
}

export function dashboardEventId(sourceId: string, eventType: DashboardEventType): string {
  const hex = createHash("sha256").update(`${PRODUCT}:${eventType}:${sourceId}`).digest("hex").slice(0, 32);
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-5${hex.slice(13, 16)}-a${hex.slice(17, 20)}-${hex.slice(20)}`;
}

/** Durable enqueue plus immediate best-effort delivery. It is deliberately a no-op when integration env is absent. */
export async function publishDashboardEvent(event: DashboardEvent): Promise<void> {
  if (!config()) return;
  const { error } = await (supabaseAdmin as any).from("dashboard_event_outbox").upsert(
    { id: event.event_id, event, next_attempt_at: new Date().toISOString() },
    { onConflict: "id", ignoreDuplicates: true },
  );
  if (error) {
    console.error("[dashboard publisher] enqueue failed:", error.message);
    return;
  }
  void drainDashboardOutbox();
}

export async function drainDashboardOutbox(): Promise<void> {
  if (!config() || draining) return;
  draining = true;
  try {
    const { data, error } = await (supabaseAdmin as any)
      .from("dashboard_event_outbox")
      .select("id,event,attempts")
      .is("delivered_at", null)
      .lte("next_attempt_at", new Date().toISOString())
      .order("created_at", { ascending: true })
      .limit(25);
    if (error) throw new Error(error.message);

    for (const row of (data ?? []) as OutboxRow[]) {
      try {
        await deliver(row.event);
        await (supabaseAdmin as any)
          .from("dashboard_event_outbox")
          .update({ delivered_at: new Date().toISOString(), last_error: null })
          .eq("id", row.id);
      } catch (error_) {
        const attempts = row.attempts + 1;
        const retryAt = new Date(Date.now() + Math.min(300_000, 1_000 * 2 ** attempts)).toISOString();
        await (supabaseAdmin as any)
          .from("dashboard_event_outbox")
          .update({
            attempts,
            next_attempt_at: retryAt,
            last_error: error_ instanceof Error ? error_.message.slice(0, 1000) : String(error_),
          })
          .eq("id", row.id);
      }
    }
  } catch (error) {
    console.error("[dashboard publisher] drain failed:", error instanceof Error ? error.message : String(error));
  } finally {
    draining = false;
  }
}

export function startDashboardOutboxWorker(): void {
  if (!config() || worker) return;
  void drainDashboardOutbox();
  worker = setInterval(() => void drainDashboardOutbox(), 15_000);
  worker.unref();
}
