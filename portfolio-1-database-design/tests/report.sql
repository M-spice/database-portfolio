\pset format aligned
SELECT seq AS "#", test_name AS test, run_as, expected, outcome,
       CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result,
       left(coalesce(message, ''), 90) AS message
  FROM test_result
 ORDER BY seq;

SELECT suite, count(*) AS tests, count(*) FILTER (WHERE passed) AS passed, count(*) FILTER (WHERE NOT passed) AS failed
  FROM test_result
 GROUP BY suite;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM test_result WHERE NOT passed) THEN
    RAISE EXCEPTION '% test(s) failed', (SELECT count(*) FROM test_result WHERE NOT passed);
  END IF;
END $$;
