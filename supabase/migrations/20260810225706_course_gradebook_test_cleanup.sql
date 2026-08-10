DO $$
DECLARE v_student uuid; v_s1 uuid; v_s2 uuid; v_s3 uuid;
BEGIN
  SELECT id INTO v_student FROM course_students WHERE display_name = 'Student 1 (rename me)' AND agency_id='126794dd-25ff-47d2-a436-724499733365';
  SELECT id INTO v_s2 FROM course_sessions WHERE session_code='F02' AND agency_id='126794dd-25ff-47d2-a436-724499733365';

  DELETE FROM course_participation WHERE student_id = v_student;
  DELETE FROM course_grade_items WHERE student_id = v_student AND item_ref LIKE 'TEST-%';
  UPDATE course_sessions SET was_held = true WHERE id = v_s2;
END $$;
