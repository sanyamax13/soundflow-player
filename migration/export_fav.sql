SELECT json_agg(row_to_json(t) ORDER BY t.liked_at) FROM (
  SELECT tr.artist, tr.title, tr.album, tr.year, tr.duration_sec, tr.isrc,
         tr.recording_mbid, tr.language, tr.genre_tags, ult.liked_at
  FROM user_liked_tracks ult JOIN tracks tr ON tr.id = ult.track_id
) t;
