-- Memeless Submission System
-- Run this in Supabase SQL Editor

-- 1. Submissions table
CREATE TABLE IF NOT EXISTS public.submissions (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    original_filename TEXT NOT NULL,
    storage_path TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 2. Admins table
CREATE TABLE IF NOT EXISTS public.admins (
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3. Storage bucket
INSERT INTO storage.buckets (id, name, public)
VALUES ('memeless-submissions', 'memeless-submissions', false)
ON CONFLICT (id) DO NOTHING;

-- 4. Enable RLS
DO $$ BEGIN
    ALTER TABLE public.submissions ENABLE ROW LEVEL SECURITY;
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    ALTER TABLE public.admins ENABLE ROW LEVEL SECURITY;
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

-- 5. Rate limit table
CREATE TABLE IF NOT EXISTS public.submission_rate_limits (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    client_id TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_rate_limits_client_created
    ON public.submission_rate_limits (client_id, created_at);

-- 6. Atomic rate limit check RPC
CREATE OR REPLACE FUNCTION public.check_submission_rate_limit(
    p_client_id TEXT,
    p_max INT DEFAULT 5,
    p_window_seconds INT DEFAULT 600
)
RETURNS TABLE(allowed BOOLEAN, remaining INT, retry_seconds INT)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    INSERT INTO public.submission_rate_limits (client_id)
    VALUES (p_client_id);

    DELETE FROM public.submission_rate_limits
    WHERE client_id = p_client_id
      AND created_at < now() - (p_window_seconds || ' seconds')::INTERVAL;

    RETURN QUERY
    SELECT
        (count(*) <= p_max),
        GREATEST(p_max - count(*)::INT, 0),
        COALESCE(EXTRACT(EPOCH FROM (
            SELECT min(created_at) + (p_window_seconds || ' seconds')::INTERVAL
            FROM public.submission_rate_limits
            WHERE client_id = p_client_id
        ) - now())::INT, 0)
    FROM public.submission_rate_limits
    WHERE client_id = p_client_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_submission_rate_limit(TEXT, INT, INT)
    TO anon, authenticated;

-- 7. Cleanup expired entries
CREATE OR REPLACE FUNCTION public.cleanup_submission_rate_limits()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    DELETE FROM public.submission_rate_limits
    WHERE created_at < now() - INTERVAL '1 hour';
END;
$$;

GRANT EXECUTE ON FUNCTION public.cleanup_submission_rate_limits()
    TO anon, authenticated;

-- 8. Submissions policies
DO $$ BEGIN
    DROP POLICY IF EXISTS "Anyone can insert submissions" ON public.submissions;
END $$;
CREATE POLICY "Anyone can insert submissions"
ON public.submissions FOR INSERT
TO anon, authenticated
WITH CHECK (true);

DO $$ BEGIN
    DROP POLICY IF EXISTS "Admins can view all submissions" ON public.submissions;
END $$;
CREATE POLICY "Admins can view all submissions"
ON public.submissions FOR SELECT
TO authenticated
USING (
    EXISTS (SELECT 1 FROM public.admins WHERE admins.user_id = auth.uid())
);

DO $$ BEGIN
    DROP POLICY IF EXISTS "Admins can update submissions" ON public.submissions;
END $$;
CREATE POLICY "Admins can update submissions"
ON public.submissions FOR UPDATE
TO authenticated
USING (
    EXISTS (SELECT 1 FROM public.admins WHERE admins.user_id = auth.uid())
);

DO $$ BEGIN
    DROP POLICY IF EXISTS "Admins can delete submissions" ON public.submissions;
END $$;
CREATE POLICY "Admins can delete submissions"
ON public.submissions FOR DELETE
TO authenticated
USING (
    EXISTS (SELECT 1 FROM public.admins WHERE admins.user_id = auth.uid())
);

-- 9. Admins table policies
DO $$ BEGIN
    DROP POLICY IF EXISTS "Admins can view admins" ON public.admins;
END $$;
CREATE POLICY "Admins can view admins"
ON public.admins FOR SELECT
TO authenticated
USING (true);

-- 10. Storage policies
DO $$ BEGIN
    DROP POLICY IF EXISTS "Authenticated users can upload to pending" ON storage.objects;
END $$;
CREATE POLICY "Authenticated users can upload to pending"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (
    bucket_id = 'memeless-submissions' AND
    name LIKE 'pending/%'
);

DO $$ BEGIN
    DROP POLICY IF EXISTS "Admins can view pending uploads" ON storage.objects;
END $$;
CREATE POLICY "Admins can view pending uploads"
ON storage.objects FOR SELECT
TO authenticated
USING (
    bucket_id = 'memeless-submissions' AND
    name LIKE 'pending/%' AND
    EXISTS (SELECT 1 FROM public.admins WHERE admins.user_id = auth.uid())
);

DO $$ BEGIN
    DROP POLICY IF EXISTS "Admins can delete pending uploads" ON storage.objects;
END $$;
CREATE POLICY "Admins can delete pending uploads"
ON storage.objects FOR DELETE
TO authenticated
USING (
    bucket_id = 'memeless-submissions' AND
    name LIKE 'pending/%' AND
    EXISTS (SELECT 1 FROM public.admins WHERE admins.user_id = auth.uid())
);

-- 11. Duel tables
CREATE TABLE IF NOT EXISTS public.duel_rooms (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    room_code TEXT UNIQUE NOT NULL,
    visibility TEXT NOT NULL DEFAULT 'public',
    status TEXT NOT NULL DEFAULT 'waiting',
    host_client_id TEXT NOT NULL,
    current_round INT NOT NULL DEFAULT 1,
    current_meme_title TEXT,
    player_1_attempts INT NOT NULL DEFAULT 5,
    player_2_attempts INT NOT NULL DEFAULT 5,
    player_1_score INT NOT NULL DEFAULT 0,
    player_2_score INT NOT NULL DEFAULT 0,
    player_1_skip_vote BOOLEAN,
    player_2_skip_vote BOOLEAN,
    timer_end_at TIMESTAMPTZ,
    winner TEXT,
    round_result JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.duel_rooms
    ADD COLUMN IF NOT EXISTS result_end_at TIMESTAMPTZ;

ALTER TABLE public.duel_rooms
    ADD COLUMN IF NOT EXISTS surrendered_by TEXT;

CREATE TABLE IF NOT EXISTS public.duel_room_players (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    room_id UUID REFERENCES public.duel_rooms(id) ON DELETE CASCADE,
    slot INT NOT NULL CHECK (slot IN (1,2)),
    client_id TEXT NOT NULL,
    nickname TEXT,
    connected BOOLEAN NOT NULL DEFAULT true,
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    joined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(room_id, slot)
);

ALTER TABLE public.duel_room_players
    ADD COLUMN IF NOT EXISTS connected BOOLEAN NOT NULL DEFAULT true;

ALTER TABLE public.duel_room_players
    ADD COLUMN IF NOT EXISTS last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now();

CREATE INDEX IF NOT EXISTS idx_duel_rooms_code
    ON public.duel_rooms (room_code);

CREATE INDEX IF NOT EXISTS idx_duel_rooms_status
    ON public.duel_rooms (status);

-- 12. Enable Duel tables for Supabase Realtime
DO $$ BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.duel_rooms;
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.duel_room_players;
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

-- 12. Room code generator
CREATE OR REPLACE FUNCTION public.generate_room_code()
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    chars TEXT := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    result TEXT := '';
    i INT;
BEGIN
    FOR i IN 1..6 LOOP
        result := result || substr(chars, floor(random() * length(chars))::int + 1, 1);
    END LOOP;
    RETURN result;
END;
$$;

-- 13. Duel RPCs
CREATE OR REPLACE FUNCTION public.create_duel_room(
    p_visibility TEXT,
    p_host_client_id TEXT,
    p_nickname TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_room_id UUID;
    v_code TEXT;
    v_tries INT := 0;
BEGIN
    IF p_visibility NOT IN ('public','private') THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Invalid visibility');
    END IF;

    LOOP
        v_code := public.generate_room_code();
        BEGIN
            INSERT INTO public.duel_rooms (room_code, visibility, host_client_id)
            VALUES (v_code, p_visibility, p_host_client_id)
            RETURNING id INTO v_room_id;
            EXIT;
        EXCEPTION
            WHEN unique_violation THEN
                v_tries := v_tries + 1;
                IF v_tries > 10 THEN
                    RETURN jsonb_build_object('ok', false, 'error', 'Failed to generate unique room code');
                END IF;
        END;
    END LOOP;

    INSERT INTO public.duel_room_players (room_id, slot, client_id, nickname)
    VALUES (v_room_id, 1, p_host_client_id, p_nickname);

    RETURN jsonb_build_object(
        'ok', true,
        'room_id', v_room_id,
        'room_code', v_code,
        'slot', 1,
        'status', 'waiting',
        'visibility', p_visibility
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.join_duel_room(
    p_room_code TEXT,
    p_client_id TEXT,
    p_nickname TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_room public.duel_rooms%ROWTYPE;
    v_count INT;
    v_existing_slot INT;
BEGIN
    SELECT * INTO v_room
    FROM public.duel_rooms
    WHERE room_code = upper(p_room_code)
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Room not found');
    END IF;

    IF v_room.status <> 'waiting' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Room is no longer available');
    END IF;

    SELECT slot INTO v_existing_slot
    FROM public.duel_room_players
    WHERE room_id = v_room.id AND client_id = p_client_id;

    IF v_existing_slot IS NOT NULL THEN
        RETURN jsonb_build_object(
            'ok', true,
            'room_id', v_room.id,
            'room_code', v_room.room_code,
            'slot', v_existing_slot,
            'status', v_room.status,
            'visibility', v_room.visibility
        );
    END IF;

    SELECT count(*) INTO v_count
    FROM public.duel_room_players
    WHERE room_id = v_room.id AND slot = 2;
    IF v_count > 0 THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Room is already full');
    END IF;

    INSERT INTO public.duel_room_players (room_id, slot, client_id, nickname)
    VALUES (v_room.id, 2, p_client_id, p_nickname);

    UPDATE public.duel_rooms
    SET updated_at = now()
    WHERE id = v_room.id;

    RETURN jsonb_build_object(
        'ok', true,
        'room_id', v_room.id,
        'room_code', v_room.room_code,
        'slot', 2,
        'status', 'waiting',
        'visibility', v_room.visibility
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.random_match(
    p_client_id TEXT,
    p_nickname TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_room public.duel_rooms%ROWTYPE;
BEGIN
    SELECT * INTO v_room
    FROM public.duel_rooms
    WHERE visibility = 'public'
      AND status = 'waiting'
            AND NOT EXISTS (
                    SELECT 1
                    FROM public.duel_room_players
                    WHERE room_id = duel_rooms.id
                        AND slot = 2
            )
    ORDER BY created_at ASC
    LIMIT 1
    FOR UPDATE SKIP LOCKED;

    IF FOUND THEN
        INSERT INTO public.duel_room_players (room_id, slot, client_id, nickname)
        VALUES (v_room.id, 2, p_client_id, p_nickname);

        UPDATE public.duel_rooms
        SET updated_at = now()
        WHERE id = v_room.id;

        RETURN jsonb_build_object(
            'ok', true,
            'room_id', v_room.id,
            'room_code', v_room.room_code,
            'slot', 2,
            'status', 'waiting',
            'visibility', v_room.visibility
        );
    END IF;

    RETURN jsonb_build_object('ok', false, 'error', 'tidak ada room tersedia');
END;
$$;

CREATE OR REPLACE FUNCTION public.set_duel_room_visibility(
    p_room_id UUID,
    p_client_id TEXT,
    p_visibility TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_room public.duel_rooms%ROWTYPE;
BEGIN
    IF p_visibility NOT IN ('public', 'private') THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Invalid visibility');
    END IF;

    SELECT * INTO v_room
    FROM public.duel_rooms
    WHERE id = p_room_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Room not found');
    END IF;

    IF v_room.host_client_id <> p_client_id THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Only host can change room visibility');
    END IF;

    IF v_room.status <> 'waiting' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Visibility can only change while waiting');
    END IF;

    UPDATE public.duel_rooms
    SET visibility = p_visibility, updated_at = now()
    WHERE id = p_room_id;

    RETURN jsonb_build_object('ok', true, 'visibility', p_visibility);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_duel_room(
    p_room_id UUID,
    p_client_id TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_room public.duel_rooms%ROWTYPE;
    v_players JSONB;
BEGIN
    SELECT * INTO v_room FROM public.duel_rooms WHERE id = p_room_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Room not found');
    END IF;

    SELECT jsonb_agg(
        jsonb_build_object(
            'slot', slot,
            'client_id', client_id,
            'nickname', nickname,
            'connected', connected,
            'last_seen_at', last_seen_at,
            'is_me', client_id = p_client_id
        )
    ) INTO v_players
    FROM public.duel_room_players
    WHERE room_id = p_room_id;

    RETURN jsonb_build_object(
        'ok', true,
        'room_id', v_room.id,
        'room_code', v_room.room_code,
        'visibility', v_room.visibility,
        'status', v_room.status,
        'host_client_id', v_room.host_client_id,
        'current_round', v_room.current_round,
        'current_meme_title', v_room.current_meme_title,
        'player_1_attempts', v_room.player_1_attempts,
        'player_2_attempts', v_room.player_2_attempts,
        'player_1_score', v_room.player_1_score,
        'player_2_score', v_room.player_2_score,
        'player_1_skip_vote', v_room.player_1_skip_vote,
        'player_2_skip_vote', v_room.player_2_skip_vote,
        'timer_end_at_ms', COALESCE((EXTRACT(EPOCH FROM v_room.timer_end_at) * 1000)::BIGINT, 0),
        'result_end_at_ms', COALESCE((EXTRACT(EPOCH FROM v_room.result_end_at) * 1000)::BIGINT, 0),
        'server_now_ms', (EXTRACT(EPOCH FROM now()) * 1000)::BIGINT,
        'winner', v_room.winner,
        'surrendered_by', v_room.surrendered_by,
        'round_result', v_room.round_result,
        'created_at', to_char(v_room.created_at, 'YYYY-MM-DD HH24:MI:SS'),
        'players', COALESCE(v_players, '[]'::jsonb)
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.leave_duel_room(
    p_room_id UUID,
    p_client_id TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_room public.duel_rooms%ROWTYPE;
    v_slot INT;
BEGIN
    SELECT * INTO v_room
    FROM public.duel_rooms
    WHERE id = p_room_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Room not found');
    END IF;

    SELECT slot INTO v_slot
    FROM public.duel_room_players
    WHERE room_id = p_room_id AND client_id = p_client_id;

    IF v_slot IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'You are not in this room');
    END IF;

    IF v_slot = 1 THEN
        DELETE FROM public.duel_rooms WHERE id = p_room_id;
        RETURN jsonb_build_object('ok', true, 'action', 'room_deleted');
    END IF;

    DELETE FROM public.duel_room_players
    WHERE room_id = p_room_id AND client_id = p_client_id;

    UPDATE public.duel_rooms
    SET updated_at = now()
    WHERE id = p_room_id;

    RETURN jsonb_build_object('ok', true, 'action', 'player_left');
END;
$$;

CREATE OR REPLACE FUNCTION public.heartbeat_duel_player(
    p_room_id UUID,
    p_client_id TEXT,
    p_connected BOOLEAN DEFAULT true
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE public.duel_room_players
    SET connected = p_connected,
        last_seen_at = now()
    WHERE room_id = p_room_id
      AND client_id = p_client_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'You are not in this room');
    END IF;

    RETURN jsonb_build_object('ok', true, 'connected', p_connected);
END;
$$;

CREATE OR REPLACE FUNCTION public.surrender_duel(
    p_room_id UUID,
    p_client_id TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_room public.duel_rooms%ROWTYPE;
    v_slot INT;
BEGIN
    SELECT * INTO v_room
    FROM public.duel_rooms
    WHERE id = p_room_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Room not found');
    END IF;

    IF v_room.status <> 'playing' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Duel is not in progress');
    END IF;

    SELECT slot INTO v_slot
    FROM public.duel_room_players
    WHERE room_id = p_room_id AND client_id = p_client_id;

    IF v_slot IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'You are not in this room');
    END IF;

    UPDATE public.duel_rooms
    SET status = 'surrendered',
        surrendered_by = p_client_id,
        winner = NULL,
        round_result = NULL,
        timer_end_at = NULL,
        result_end_at = NULL,
        updated_at = now()
    WHERE id = p_room_id;

    RETURN jsonb_build_object('ok', true, 'slot', v_slot);
END;
$$;

CREATE OR REPLACE FUNCTION public.start_duel_game(
    p_room_id UUID,
    p_client_id TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_room public.duel_rooms%ROWTYPE;
    v_count INT;
BEGIN
    SELECT * INTO v_room FROM public.duel_rooms WHERE id = p_room_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Room not found');
    END IF;

    IF v_room.host_client_id <> p_client_id THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Only host can start the game');
    END IF;

    IF v_room.status <> 'waiting' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Room is not in waiting state');
    END IF;

    SELECT count(*) INTO v_count FROM public.duel_room_players WHERE room_id = p_room_id;
    IF v_count < 2 THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Waiting for opponent');
    END IF;

    UPDATE public.duel_rooms
    SET status = 'playing', updated_at = now()
    WHERE id = p_room_id;

    RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.start_duel_round(
    p_room_id UUID,
    p_meme_title TEXT,
    p_timer_seconds INT DEFAULT 10
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_room public.duel_rooms%ROWTYPE;
BEGIN
    SELECT * INTO v_room FROM public.duel_rooms WHERE id = p_room_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Room not found');
    END IF;

    IF v_room.status NOT IN ('playing') THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Room is not in playing state');
    END IF;

    UPDATE public.duel_rooms
    SET current_meme_title = p_meme_title,
        player_1_attempts = 5,
        player_2_attempts = 5,
        player_1_skip_vote = NULL,
        player_2_skip_vote = NULL,
        winner = NULL,
        round_result = NULL,
        timer_end_at = now() + (p_timer_seconds || ' seconds')::INTERVAL,
        result_end_at = NULL,
        updated_at = now()
    WHERE id = p_room_id;

    RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.submit_duel_answer(
    p_room_id UUID,
    p_client_id TEXT,
    p_answer TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_room public.duel_rooms%ROWTYPE;
    v_slot INT;
    v_attempts INT;
    v_is_correct BOOLEAN;
BEGIN
    SELECT * INTO v_room FROM public.duel_rooms WHERE id = p_room_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Room not found');
    END IF;

    IF v_room.status <> 'playing' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Room is not in playing state');
    END IF;

    IF v_room.winner IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Round already finished');
    END IF;

    SELECT slot INTO v_slot
    FROM public.duel_room_players
    WHERE room_id = p_room_id AND client_id = p_client_id
    LIMIT 1;

    IF v_slot IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'You are not in this room');
    END IF;

    IF v_slot = 1 THEN
        v_attempts := v_room.player_1_attempts;
    ELSE
        v_attempts := v_room.player_2_attempts;
    END IF;

    IF v_attempts <= 0 THEN
        RETURN jsonb_build_object('ok', false, 'error', 'No attempts left');
    END IF;

    v_is_correct := trim(lower(p_answer)) = trim(lower(v_room.current_meme_title));

    IF v_is_correct THEN
        UPDATE public.duel_rooms
        SET winner = CASE WHEN v_slot = 1 THEN 'player_1' ELSE 'player_2' END,
            player_1_score = player_1_score + CASE WHEN v_slot = 1 THEN 1 ELSE 0 END,
            player_2_score = player_2_score + CASE WHEN v_slot = 2 THEN 1 ELSE 0 END,
            result_end_at = now() + INTERVAL '3 seconds',
            round_result = jsonb_build_object(
                'winner_slot', v_slot,
                'correct_answer', v_room.current_meme_title,
                'reason', 'correct'
            ),
            updated_at = now()
        WHERE id = p_room_id;

        RETURN jsonb_build_object('ok', true, 'correct', true, 'winner_slot', v_slot);
    ELSE
        IF v_slot = 1 THEN
            UPDATE public.duel_rooms SET player_1_attempts = player_1_attempts - 1, updated_at = now() WHERE id = p_room_id;
        ELSE
            UPDATE public.duel_rooms SET player_2_attempts = player_2_attempts - 1, updated_at = now() WHERE id = p_room_id;
        END IF;

        RETURN jsonb_build_object('ok', true, 'correct', false, 'attempts_left', v_attempts - 1);
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.vote_skip_duel(
    p_room_id UUID,
    p_client_id TEXT,
    p_vote BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_room public.duel_rooms%ROWTYPE;
    v_slot INT;
    v_p1_skip BOOLEAN;
    v_p2_skip BOOLEAN;
BEGIN
    SELECT * INTO v_room FROM public.duel_rooms WHERE id = p_room_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Room not found');
    END IF;

    IF v_room.status <> 'playing' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Room is not in playing state');
    END IF;

    IF v_room.winner IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Round already finished');
    END IF;

    SELECT slot INTO v_slot
    FROM public.duel_room_players
    WHERE room_id = p_room_id AND client_id = p_client_id
    LIMIT 1;

    IF v_slot IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'You are not in this room');
    END IF;

    IF v_slot = 1 THEN
        UPDATE public.duel_rooms SET player_1_skip_vote = p_vote, updated_at = now() WHERE id = p_room_id;
    ELSE
        UPDATE public.duel_rooms SET player_2_skip_vote = p_vote, updated_at = now() WHERE id = p_room_id;
    END IF;

    SELECT player_1_skip_vote, player_2_skip_vote INTO v_p1_skip, v_p2_skip
    FROM public.duel_rooms WHERE id = p_room_id;

    IF v_p1_skip = true AND v_p2_skip = true THEN
        UPDATE public.duel_rooms
        SET winner = 'skip',
            result_end_at = now() + INTERVAL '3 seconds',
            round_result = jsonb_build_object(
                'winner_slot', NULL,
                'correct_answer', current_meme_title,
                'reason', 'skip'
            ),
            updated_at = now()
        WHERE id = p_room_id;

        RETURN jsonb_build_object('ok', true, 'skip_approved', true);
    END IF;

    RETURN jsonb_build_object('ok', true, 'skip_approved', false);
END;
$$;

CREATE OR REPLACE FUNCTION public.finish_duel_round(
    p_room_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_room public.duel_rooms%ROWTYPE;
BEGIN
    SELECT * INTO v_room FROM public.duel_rooms WHERE id = p_room_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Room not found');
    END IF;

    IF v_room.winner IS NULL THEN
        UPDATE public.duel_rooms
        SET winner = 'draw',
            result_end_at = now() + INTERVAL '3 seconds',
            round_result = jsonb_build_object(
                'winner_slot', NULL,
                'correct_answer', current_meme_title,
                'reason', 'timeout'
            ),
            updated_at = now()
        WHERE id = p_room_id;
    END IF;

    RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.next_duel_round(
    p_room_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_room public.duel_rooms%ROWTYPE;
BEGIN
    SELECT * INTO v_room FROM public.duel_rooms WHERE id = p_room_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Room not found');
    END IF;

    IF v_room.winner IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Current round not finished');
    END IF;

    IF v_room.result_end_at IS NOT NULL AND now() < v_room.result_end_at THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Result pause is still active');
    END IF;

    UPDATE public.duel_rooms
    SET current_round = current_round + 1,
        current_meme_title = NULL,
        player_1_attempts = 5,
        player_2_attempts = 5,
        player_1_skip_vote = NULL,
        player_2_skip_vote = NULL,
        winner = NULL,
        round_result = NULL,
        timer_end_at = NULL,
        result_end_at = NULL,
        updated_at = now()
    WHERE id = p_room_id;

    RETURN jsonb_build_object('ok', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.cleanup_duel_rooms()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM public.duel_rooms
    WHERE updated_at < now() - INTERVAL '10 minutes';
END;
$$;

-- 14. Enable RLS for duel tables
DO $$ BEGIN
    ALTER TABLE public.duel_rooms ENABLE ROW LEVEL SECURITY;
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    ALTER TABLE public.duel_room_players ENABLE ROW LEVEL SECURITY;
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

-- 15. Duel RLS policies
DO $$ BEGIN
    DROP POLICY IF EXISTS "Anyone can create rooms" ON public.duel_rooms;
END $$;
CREATE POLICY "Anyone can create rooms"
ON public.duel_rooms FOR INSERT
TO anon, authenticated
WITH CHECK (true);

DO $$ BEGIN
    DROP POLICY IF EXISTS "Anyone can view rooms" ON public.duel_rooms;
END $$;
CREATE POLICY "Anyone can view rooms"
ON public.duel_rooms FOR SELECT
TO anon, authenticated
USING (true);

DO $$ BEGIN
    DROP POLICY IF EXISTS "Anyone can update rooms" ON public.duel_rooms;
END $$;
CREATE POLICY "Anyone can update rooms"
ON public.duel_rooms FOR UPDATE
TO anon, authenticated
USING (true);

DO $$ BEGIN
    DROP POLICY IF EXISTS "Anyone can view players" ON public.duel_room_players;
END $$;
CREATE POLICY "Anyone can view players"
ON public.duel_room_players FOR SELECT
TO anon, authenticated
USING (true);

DO $$ BEGIN
    DROP POLICY IF EXISTS "Anyone can insert players" ON public.duel_room_players;
END $$;
CREATE POLICY "Anyone can insert players"
ON public.duel_room_players FOR INSERT
TO anon, authenticated
WITH CHECK (true);

GRANT EXECUTE ON FUNCTION public.generate_room_code() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_duel_room(TEXT, TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.join_duel_room(TEXT, TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.random_match(TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_duel_room_visibility(UUID, TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_duel_room(UUID, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.leave_duel_room(UUID, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.heartbeat_duel_player(UUID, TEXT, BOOLEAN) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.surrender_duel(UUID, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.start_duel_game(UUID, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.start_duel_round(UUID, TEXT, INT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.submit_duel_answer(UUID, TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.vote_skip_duel(UUID, TEXT, BOOLEAN) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.finish_duel_round(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.next_duel_round(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cleanup_duel_rooms() TO anon, authenticated;
