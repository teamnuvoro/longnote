// deno test --allow-env supabase/functions/_shared/ip_bucket_test.ts
import { assertEquals } from "jsr:@std/assert@1";
import { ipBucket } from "./common.ts";

Deno.test("IPv4 stays as is", () => assertEquals(ipBucket("49.36.10.7"), "49.36.10.7"));
Deno.test("IPv6 -> /64", () => {
  assertEquals(ipBucket("2409:4042:2d9a:1c3e:a1b2:c3d4:e5f6:789"), "2409:4042:2d9a:1c3e::/64");
  assertEquals(ipBucket("2409:4042:2d9a:1c3e::1"), "2409:4042:2d9a:1c3e::/64");
  assertEquals(ipBucket("2409:4042:2D9A:1C3E:ffff::"), "2409:4042:2d9a:1c3e::/64");
  assertEquals(ipBucket("2409:4042::5"), "2409:4042:0:0::/64");
  assertEquals(ipBucket("[2409:4042:2d9a:1c3e::9]"), "2409:4042:2d9a:1c3e::/64");
  assertEquals(ipBucket("fe80::1%en0"), "fe80:0:0:0::/64");
  assertEquals(ipBucket("2409:0042:00aa:0001:1:2:3:4"), "2409:42:aa:1::/64");
});
Deno.test("same /64, different hosts -> same bucket", () =>
  assertEquals(ipBucket("2401:4900:1c5a:9f00::aaaa"), ipBucket("2401:4900:1c5a:9f00:1234:5678:9abc:def0")));
Deno.test("IPv4-mapped -> IPv4", () => assertEquals(ipBucket("::ffff:49.36.10.7"), "49.36.10.7"));
Deno.test("garbage passes through", () => assertEquals(ipBucket("not-an-ip:x"), "not-an-ip:x"));
