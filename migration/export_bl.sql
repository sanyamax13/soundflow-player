SELECT json_agg(row_to_json(t) ORDER BY t.blacklisted_at) FROM (
  SELECT artist, title, normalized_key, kind, reason, blacklisted_at, expires_at
  FROM user_track_blacklist
) t;
