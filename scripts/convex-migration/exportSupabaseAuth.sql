SELECT jsonb_build_object(
  'users',
    (SELECT COALESCE(jsonb_agg(to_jsonb(auth_users) ORDER BY auth_users.id), '[]'::jsonb)
     FROM (
       SELECT
         u.id,
         u.email,
         u.encrypted_password,
         u.email_confirmed_at,
         u.confirmed_at,
         u.created_at,
         u.updated_at,
         u.raw_user_meta_data,
         u.raw_app_meta_data,
         COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'id', i.id,
               'user_id', i.user_id,
               'provider', i.provider,
               'provider_id', i.provider_id,
               'identity_data', i.identity_data,
               'created_at', i.created_at,
               'updated_at', i.updated_at
             )
             ORDER BY i.provider, i.id
           ) FILTER (WHERE i.id IS NOT NULL),
           '[]'::jsonb
         ) AS identities
       FROM auth.users u
       LEFT JOIN auth.identities i ON i.user_id = u.id
       WHERE u.deleted_at IS NULL
       GROUP BY u.id
     ) AS auth_users)
) AS auth_export;
