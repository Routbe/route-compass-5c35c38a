import { describe, expect, it } from "vitest";
import { cronGuard } from "./cron-auth";

const env = { CRON_SECRET: "vercel-secret-0123456789", LOVABLE_CRON_SECRET: "other-secret-0123456789" };
const req = (headers: Record<string, string>, url = "https://rout.be/api/public/cron/cleanup-assets") => new Request(url, { headers });

describe("cleanup job password", () => {
  it("accepts either configured secret from a header", async () => {
    expect(await cronGuard(req({ authorization: "Bearer vercel-secret-0123456789" }), env)).toBeNull();
    expect(await cronGuard(req({ "x-cron-secret": "other-secret-0123456789" }), env)).toBeNull();
  });
  it("refuses a secret in the URL, a wrong or a missing one", async () => {
    expect((await cronGuard(req({}, "https://rout.be/api/public/cron/cleanup-assets?token=vercel-secret-0123456789"), env))?.status).toBe(401);
    expect((await cronGuard(req({ authorization: "Bearer nope" }), env))?.status).toBe(401);
    expect((await cronGuard(req({}), env))?.status).toBe(401);
  });
  it("is closed when no secret is configured", async () => {
    expect((await cronGuard(req({ authorization: "Bearer x" }), {}))?.status).toBe(503);
  });
});
