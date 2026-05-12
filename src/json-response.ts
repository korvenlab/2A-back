import type { Context } from "hono";
import type { ContentfulStatusCode } from "hono/utils/http-status";

export const JSON_CONTENT_TYPE = "application/json; charset=utf-8";

export type KorvenErrorCode =
  | "UNAUTHORIZED"
  | "VALIDATION_ERROR"
  | "BAD_REQUEST"
  | "FORBIDDEN"
  | "CONFLICT"
  | "INTERNAL_ERROR"
  | "UNAVAILABLE"
  | "NOT_FOUND";

export function jsonOk<T extends Record<string, unknown>>(c: Context, body: T, status: ContentfulStatusCode = 200) {
  c.header("Content-Type", JSON_CONTENT_TYPE);
  return c.json(body, status);
}

export function jsonFail(c: Context, status: ContentfulStatusCode, error: string, code: KorvenErrorCode) {
  c.header("Content-Type", JSON_CONTENT_TYPE);
  return c.json({ ok: false, error, code }, status);
}
