INSERT INTO public.course_sessions (agency_id, school_year, session_code, session_date, semester, title, was_held)
VALUES
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'F01', '2026-08-20', 'fall', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'F02', '2026-08-27', 'fall', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'F03', '2026-09-03', 'fall', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'F04', '2026-09-10', 'fall', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'F05', '2026-09-17', 'fall', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'F06', '2026-09-24', 'fall', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'F07', '2026-10-01', 'fall', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'F08', '2026-10-08', 'fall', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'F09', '2026-10-15', 'fall', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'F10', '2026-10-22', 'fall', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'F11', '2026-10-29', 'fall', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'F12', '2026-11-05', 'fall', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'F13', '2026-11-12', 'fall', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'F14', '2026-11-19', 'fall', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'S01', '2027-01-14', 'spring', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'S02', '2027-01-21', 'spring', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'S03', '2027-01-28', 'spring', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'S04', '2027-02-04', 'spring', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'S05', '2027-02-11', 'spring', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'S06', '2027-02-18', 'spring', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'S07', '2027-02-25', 'spring', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'S08', '2027-03-04', 'spring', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'S09', '2027-03-18', 'spring', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'S10', '2027-03-25', 'spring', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'S11', '2027-04-01', 'spring', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'S12', '2027-04-08', 'spring', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'S13', '2027-04-15', 'spring', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'S14', '2027-04-22', 'spring', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'S15', '2027-04-29', 'spring', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'S16', '2027-05-06', 'spring', NULL, true)
ON CONFLICT (agency_id, school_year, session_code) DO NOTHING;

INSERT INTO public.course_students (agency_id, school_year, display_name, grade_level, is_active)
VALUES
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'Student 1 (rename me)', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'Student 2 (rename me)', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'Student 3 (rename me)', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'Student 4 (rename me)', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'Student 5 (rename me)', NULL, true),
('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-27', 'Student 6 (rename me)', NULL, true)
ON CONFLICT (agency_id, school_year, display_name) DO NOTHING;
