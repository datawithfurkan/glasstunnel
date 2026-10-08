# Glass Tunnel Convex Backend

This Convex backend is the migration target for Supabase account/control-plane rows:

- `accountProfiles`
- `accountDevices`
- `devicePairings`
- `pushSubscriptions`
- `hostLinkCodes`
- `deviceApprovalRequests`

It also hosts the Better Auth component used to migrate Supabase Auth users while
preserving legacy Supabase user UUIDs as Better Auth `userId` values.

The Cloudflare Durable Object relay remains the WebSocket signaling layer.
