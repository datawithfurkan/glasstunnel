SELECT jsonb_build_object(
  'profiles',
    (SELECT COALESCE(jsonb_agg(to_jsonb(profiles) ORDER BY profiles.user_id), '[]'::jsonb)
     FROM (
       SELECT user_id, email, display_name, avatar_url, created_at, updated_at
       FROM public.profiles
     ) AS profiles),
  'devices',
    (SELECT COALESCE(jsonb_agg(to_jsonb(devices) ORDER BY devices.id), '[]'::jsonb)
     FROM (
       SELECT id, user_id, device_id, public_key_b64, label, kind, platform, app_version,
              last_seen_at, revoked_at, metadata, created_at, updated_at
       FROM public.devices
     ) AS devices),
  'device_pairings',
    (SELECT COALESCE(jsonb_agg(to_jsonb(device_pairings) ORDER BY device_pairings.id), '[]'::jsonb)
     FROM (
       SELECT id, owner_user_id, host_device_uuid, phone_device_uuid, metadata,
              paired_at, revoked_at, updated_at
       FROM public.device_pairings
     ) AS device_pairings),
  'push_subscriptions',
    (SELECT COALESCE(jsonb_agg(to_jsonb(push_subscriptions) ORDER BY push_subscriptions.id), '[]'::jsonb)
     FROM (
       SELECT id, user_id, device_uuid, endpoint, p256dh, auth, user_agent, metadata,
              created_at, updated_at, last_seen_at, revoked_at
       FROM public.push_subscriptions
     ) AS push_subscriptions),
  'host_link_codes',
    (SELECT COALESCE(jsonb_agg(to_jsonb(host_link_codes) ORDER BY host_link_codes.id), '[]'::jsonb)
     FROM (
       SELECT id, code, host_device_id, host_public_key_b64, host_label, host_metadata,
              created_at, expires_at, consumed_at, claimed_user_id
       FROM public.host_link_codes
     ) AS host_link_codes),
  'device_approval_requests',
    (SELECT COALESCE(jsonb_agg(to_jsonb(device_approval_requests) ORDER BY device_approval_requests.id), '[]'::jsonb)
     FROM (
       SELECT id, owner_user_id, host_device_uuid, requester_device_uuid, requester_device_id,
              requester_public_key_b64, requester_label, status, metadata, created_at,
              updated_at, responded_at
       FROM public.device_approval_requests
     ) AS device_approval_requests)
) AS account_plane_export;
