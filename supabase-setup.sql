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
ALTER TABLE public.submissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admins ENABLE ROW LEVEL SECURITY;

-- 5. Submissions policies
CREATE POLICY "Anyone can insert submissions"
ON public.submissions FOR INSERT
TO anon, authenticated
WITH CHECK (true);

CREATE POLICY "Admins can view all submissions"
ON public.submissions FOR SELECT
TO authenticated
USING (
    EXISTS (SELECT 1 FROM public.admins WHERE admins.user_id = auth.uid())
);

CREATE POLICY "Admins can update submissions"
ON public.submissions FOR UPDATE
TO authenticated
USING (
    EXISTS (SELECT 1 FROM public.admins WHERE admins.user_id = auth.uid())
);

CREATE POLICY "Admins can delete submissions"
ON public.submissions FOR DELETE
TO authenticated
USING (
    EXISTS (SELECT 1 FROM public.admins WHERE admins.user_id = auth.uid())
);

-- 6. Admins table policies
CREATE POLICY "Admins can view admins"
ON public.admins FOR SELECT
TO authenticated
USING (
    EXISTS (SELECT 1 FROM public.admins WHERE admins.user_id = auth.uid())
);

-- 7. Storage policies
CREATE POLICY "Authenticated users can upload to pending"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (
    bucket_id = 'memeless-submissions' AND
    name LIKE 'pending/%'
);

CREATE POLICY "Admins can view pending uploads"
ON storage.objects FOR SELECT
TO authenticated
USING (
    bucket_id = 'memeless-submissions' AND
    name LIKE 'pending/%' AND
    EXISTS (SELECT 1 FROM public.admins WHERE admins.user_id = auth.uid())
);

CREATE POLICY "Admins can delete pending uploads"
ON storage.objects FOR DELETE
TO authenticated
USING (
    bucket_id = 'memeless-submissions' AND
    name LIKE 'pending/%' AND
    EXISTS (SELECT 1 FROM public.admins WHERE admins.user_id = auth.uid())
);
