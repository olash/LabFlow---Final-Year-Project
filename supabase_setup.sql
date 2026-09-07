-- ================================================================
-- LabFlow Supabase Setup Script
-- Run this ENTIRE script in: Supabase Dashboard → SQL Editor
-- ================================================================

-- ================================================================
-- 1. HELPER FUNCTION (avoids RLS recursion)
-- ================================================================
CREATE OR REPLACE FUNCTION public.is_lecturer()
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role = 'lecturer'
  );
$$ LANGUAGE sql SECURITY DEFINER STABLE;


-- ================================================================
-- 2. TABLES
-- ================================================================

-- Profiles (linked to auth.users)
CREATE TABLE IF NOT EXISTS public.profiles (
  id          UUID REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
  role        TEXT NOT NULL CHECK (role IN ('student', 'lecturer')),
  full_name   TEXT NOT NULL,
  matric_number TEXT UNIQUE,   -- students only
  staff_id    TEXT UNIQUE,     -- lecturers only
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- Courses
CREATE TABLE IF NOT EXISTS public.courses (
  id    UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  code  TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL
);

-- Submissions
CREATE TABLE IF NOT EXISTS public.submissions (
  id           UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  student_id   UUID REFERENCES public.profiles(id) NOT NULL,
  course_id    UUID REFERENCES public.courses(id) NOT NULL,
  file_name    TEXT NOT NULL,
  file_path    TEXT NOT NULL,
  submitted_at TIMESTAMPTZ DEFAULT NOW(),
  status       TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'graded')),
  score        INTEGER CHECK (score >= 0 AND score <= 100),
  feedback     TEXT,
  graded_by    UUID REFERENCES public.profiles(id),
  graded_at    TIMESTAMPTZ
);


-- ================================================================
-- 3. ROW LEVEL SECURITY
-- ================================================================
ALTER TABLE public.profiles    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.courses     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.submissions ENABLE ROW LEVEL SECURITY;

-- Profiles: users read own profile; lecturers read all profiles
CREATE POLICY "profiles_select" ON public.profiles
  FOR SELECT USING (auth.uid() = id OR public.is_lecturer());

-- Courses: anyone authenticated can read
CREATE POLICY "courses_select" ON public.courses
  FOR SELECT USING (true);

-- Submissions: students insert own
CREATE POLICY "submissions_insert_student" ON public.submissions
  FOR INSERT WITH CHECK (auth.uid() = student_id);

-- Submissions: students read own
CREATE POLICY "submissions_select_student" ON public.submissions
  FOR SELECT USING (auth.uid() = student_id);

-- Submissions: lecturers read all
CREATE POLICY "submissions_select_lecturer" ON public.submissions
  FOR SELECT USING (public.is_lecturer());

-- Submissions: lecturers update (grade)
CREATE POLICY "submissions_update_lecturer" ON public.submissions
  FOR UPDATE USING (public.is_lecturer());


-- ================================================================
-- 4. AUTO-CREATE PROFILE ON USER SIGNUP (TRIGGER)
-- ================================================================
-- When a user is created via the Supabase Dashboard with user_metadata,
-- this trigger automatically creates their profile row.
--
-- Required user_metadata JSON:
--   Students:  {"role":"student", "full_name":"...", "matric_number":"..."}
--   Lecturers: {"role":"lecturer", "full_name":"...", "staff_id":"..."}

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, role, full_name, matric_number, staff_id)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data ->> 'role', 'student'),
    COALESCE(NEW.raw_user_meta_data ->> 'full_name', 'Unknown User'),
    NEW.raw_user_meta_data ->> 'matric_number',
    NEW.raw_user_meta_data ->> 'staff_id'
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Drop existing trigger if present, then create
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();


-- ================================================================
-- 5. STORAGE BUCKET & POLICIES
-- ================================================================

-- Create private bucket for lab reports
INSERT INTO storage.buckets (id, name, public)
VALUES ('lab-reports', 'lab-reports', false)
ON CONFLICT (id) DO NOTHING;

-- Students can upload to their own folder (userId/...)
CREATE POLICY "storage_insert_student" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'lab-reports' AND
    (storage.foldername(name))[1] = auth.uid()::text
  );

-- Students can read their own files
CREATE POLICY "storage_select_student" ON storage.objects
  FOR SELECT USING (
    bucket_id = 'lab-reports' AND
    (storage.foldername(name))[1] = auth.uid()::text
  );

-- Lecturers can read all files
CREATE POLICY "storage_select_lecturer" ON storage.objects
  FOR SELECT USING (
    bucket_id = 'lab-reports' AND
    public.is_lecturer()
  );


-- ================================================================
-- 6. SEED DATA
-- ================================================================
INSERT INTO public.courses (code, title) VALUES
  ('EEG 401', 'Control Engineering Lab'),
  ('EEG 403', 'Power Systems Lab'),
  ('MEG 312', 'Fluid Mechanics')
ON CONFLICT (code) DO NOTHING;


-- ================================================================
-- 7. DONE! Now create test users.
-- ================================================================
--
-- Go to:  Supabase Dashboard → Authentication → Users → "Add User"
--
-- ┌─────────────────────────────────────────────────────────────────┐
-- │ TEST STUDENT                                                    │
-- │ Email:    190403022@student.labflow.edu                         │
-- │ Password: test1234                                              │
-- │ Check:    Auto Confirm User                                     │
-- │ User Metadata (JSON):                                           │
-- │   {                                                             │
-- │     "role": "student",                                          │
-- │     "full_name": "Sheriff Abdurrahman",                         │
-- │     "matric_number": "190403022"                                │
-- │   }                                                             │
-- ├─────────────────────────────────────────────────────────────────┤
-- │ TEST LECTURER                                                   │
-- │ Email:    L001@staff.labflow.edu                                │
-- │ Password: test1234                                              │
-- │ Check:    Auto Confirm User                                     │
-- │ User Metadata (JSON):                                           │
-- │   {                                                             │
-- │     "role": "lecturer",                                         │
-- │     "full_name": "Dr. Johnson",                                 │
-- │     "staff_id": "L001"                                          │
-- │   }                                                             │
-- └─────────────────────────────────────────────────────────────────┘
--
-- The trigger (step 4) will automatically create profile rows for them.
