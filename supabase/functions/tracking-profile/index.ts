// tracking-profile: the app's "tracking profile" for server-side subscription
// events (docs/BACKEND-API.md 4.7). One row per user (upsert). Sent by the app
// at most once per launch and when it changes; share_analytics=false stores
// only that (the server then sends no events for this user).

import { admin, ApiError, handle, json, readJson, requireUser } from "../_shared/common.ts";
import { ProfileError, profileRow } from "../_shared/tracking_profile.ts";

Deno.serve(handle(async (req) => {
  const user = await requireUser(req);
  const body = await readJson(req, 4_000);
  let row: Record<string, unknown>;
  try {
    row = profileRow(body);
  } catch (e) {
    throw new ApiError("bad_request", e instanceof ProfileError ? e.message : "Bad profile.");
  }
  const { error } = await admin().from("tracking_profiles")
    .upsert({ user_id: user.id, ...row }, { onConflict: "user_id" });
  if (error) throw new ApiError("server_error", "store failed");
  return json(200, { ok: true });
}));
