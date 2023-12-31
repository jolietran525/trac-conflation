--------------------------------------------
		/** BOUNDING BOX **/
--------------------------------------------

---------- OSM ------------

-- highway = footway, footway = sidewalk
CREATE TABLE jolie_uni2.osm_sw AS (
	SELECT *
	FROM planet_osm_line
	WHERE	highway = 'footway' AND
			tags -> 'footway' = 'sidewalk' AND 
			way && st_setsrid( st_makebox2d( st_makepoint(-13615706,6049150), st_makepoint(-13614794,6050673)), 3857) ); -- 184

ALTER TABLE jolie_uni2.osm_sw RENAME COLUMN way TO geom;



-- points
CREATE table jolie_uni2.osm_point AS (
	SELECT *
	FROM planet_osm_point
	WHERE
			way && st_setsrid( st_makebox2d( st_makepoint(-13615706,6049150), st_makepoint(-13614794,6050673)), 3857) ); -- 1452

ALTER TABLE jolie_uni2.osm_point RENAME COLUMN way TO geom;

-- highway = footway, footway = crossing
CREATE TABLE jolie_uni2.osm_crossing AS (
	SELECT *
	FROM planet_osm_line
	WHERE   highway = 'footway' AND 
			tags -> 'footway' = 'crossing' AND 
			way && st_setsrid( st_makebox2d( st_makepoint(-13615706,6049150), st_makepoint(-13614794,6050673)), 3857) ); -- 116

ALTER TABLE jolie_uni2.osm_crossing RENAME COLUMN way TO geom;


-- highway = footway, footway IS NULL OR footway not sidewalk/crossing
CREATE TABLE jolie_uni2.osm_footway_null AS (
	SELECT *
	FROM planet_osm_line
	WHERE 	highway = 'footway' AND 
			(tags -> 'footway' IS NULL OR 
			tags -> 'footway' NOT IN ('sidewalk', 'crossing'))  AND
			way && st_setsrid( st_makebox2d( st_makepoint(-13615706,6049150), st_makepoint(-13614794,6050673)), 3857)  ); -- 910
		
ALTER TABLE jolie_uni2.osm_footway_null RENAME COLUMN way TO geom;


--------- ARNOLD in bellevue ----------
CREATE TABLE jolie_uni2.arnold_roads AS (
	SELECT *
	FROM arnold.wapr_linestring 
	WHERE geom && st_setsrid( st_makebox2d( st_makepoint(-13615706,6049150), st_makepoint(-13614794,6050673)), 3857)
	ORDER BY routeid, beginmeasure, endmeasure); -- 23

	
	
-- Create a geom index
CREATE INDEX sw_geom ON jolie_uni2.osm_sw USING GIST (geom);
CREATE INDEX crossing_geom ON jolie_uni2.osm_crossing USING GIST (geom);
CREATE INDEX point_geom ON jolie_uni2.osm_point USING GIST (geom);
CREATE INDEX footway_null_geom ON jolie_uni2.osm_footway_null USING GIST (geom);
CREATE INDEX arnold_roads_geom ON jolie_uni2.arnold_roads USING GIST (geom);


--------------------------------------------
			/* CONFLATION */
--------------------------------------------


---- STEP 1: Dealing with crossing
	-- assumption: all of the crossing are referred to as footway=crossing

CREATE TABLE jolie_uni2.confation_crossing (osm_id, road_num, arnold_objectid, osm_geom) AS
	SELECT crossing.osm_id AS osm_id, ROW_NUMBER() OVER (PARTITION BY crossing.osm_id ORDER BY road.og_objectid) AS road_num, road.og_objectid AS arnold_objectid, crossing.geom AS osm_geom
	FROM jolie_uni2.osm_crossing crossing
	JOIN jolie_uni2.arnold_roads road
	ON ST_Intersects(crossing.geom, road.geom) -- 67 crossing have road associated TO it (there are duplicates because the crossing intersects with 2 roads at the same time)

---- STEP 2: Dealing with entrances
	-- assumption: entrances are small footway=sidewalk segments that intersect with a point that have a tag of entrance=*
	
CREATE TABLE jolie_uni2.confation_entrances AS
	SELECT entrance.osm_id, entrance.geom AS osm_geom
	FROM jolie_uni2.osm_point point
	JOIN jolie_uni2.osm_sw entrance
	ON ST_intersects(entrance.geom, point.geom)
	WHERE point.tags -> 'entrance' IS NOT NULL 			


	
---- STEP 3: Dealing with connecting link
	-- assumption 1: a link connects the sidewalk to the crossing
	-- note: a link might or might not have a footway='sidewalk' tag

	
CREATE TABLE jolie_uni2.confation_connlink (
	osm_id INT8,
	road_num INT4,
	arnold_objectid INT8,
	osm_geom GEOMETRY(LineString, 3857)
)

-- STEP 3.1: Deal with links (footway = sidewalk) that are connected to crossing and less than 12 meters

		-- check point: segments (footway=sidewalk) intersects crossing (conlfated)
SELECT link.osm_id AS osm_id, ROW_NUMBER() OVER (PARTITION BY link.osm_id ORDER BY crossing.arnold_objectid) AS road_num, crossing.arnold_objectid AS arnold_objectid, link.geom AS osm_geom
    FROM jolie_uni2.confation_crossing crossing
    JOIN jolie_uni2.osm_sw link
    ON ST_Intersects(crossing.osm_geom, st_startpoint(link.geom)) OR ST_Intersects(crossing.osm_geom, st_endpoint(link.geom))
    WHERE ST_length(link.geom) < 12 -- 49

INSERT INTO jolie_uni2.confation_connlink (osm_id, road_num, arnold_objectid, osm_geom)
	WITH connlink_rn AS 
		(SELECT DISTINCT ON (link.osm_id, crossing.arnold_objectid)  link.osm_id AS osm_id, crossing.arnold_objectid AS arnold_objectid, link.geom AS osm_geom, crossing.osm_geom AS cross_geom
	    FROM jolie_uni2.confation_crossing crossing
	    JOIN jolie_uni2.osm_sw link
	    ON ST_Intersects(crossing.osm_geom, st_startpoint(link.geom)) OR ST_Intersects(crossing.osm_geom, st_endpoint(link.geom))
	    WHERE ST_length(link.geom) < 12)
	SELECT osm_id, ROW_NUMBER() OVER (PARTITION BY osm_id ORDER BY arnold_objectid) AS road_num, arnold_objectid, osm_geom
	FROM connlink_rn  --49


-- STEP 3.2: deal with link that are not tagged as sidewalk/crossing

SELECT link.osm_id AS link_id, ROW_NUMBER() OVER (PARTITION BY link.osm_id ORDER BY crossing.arnold_objectid) AS road_num, crossing.arnold_objectid AS arnold_objectid, link.geom AS link_geom, crossing.osm_geom
		FROM jolie_uni2.osm_footway_null link
		JOIN jolie_uni2.confation_crossing crossing
		ON ST_Intersects(link.geom, crossing.osm_geom)  
		WHERE ST_Length(link.geom) < 12
		ORDER BY link.osm_id; -- 33
	
	-- check point: how highway=footway and footway IS NULL vs crossing (conflated) are connected?
INSERT INTO jolie_uni2.confation_connlink (osm_id, road_num, arnold_objectid, osm_geom)
	WITH connlink_rn AS 
		(SELECT DISTINCT ON (link.osm_id, crossing.arnold_objectid)  link.osm_id AS osm_id, crossing.arnold_objectid AS arnold_objectid, link.geom AS osm_geom, crossing.osm_geom AS cross_geom
	    FROM jolie_uni2.confation_crossing crossing
	    JOIN jolie_uni2.osm_footway_null link
	    ON ST_Intersects(crossing.osm_geom, st_startpoint(link.geom)) OR ST_Intersects(crossing.osm_geom, st_endpoint(link.geom))
	    WHERE ST_length(link.geom) < 12)
	SELECT osm_id, ROW_NUMBER() OVER (PARTITION BY osm_id ORDER BY arnold_objectid) AS road_num, arnold_objectid, osm_geom
	FROM connlink_rn; -- 30


SELECT *
FROM jolie_uni2.confation_connlink


---- STEP 3.3: Give a table that include all connlink regardless of it conflated to the road or not
SELECT link.osm_id AS link_osm_id, ROW_NUMBER() OVER (PARTITION BY link.osm_id ORDER BY crossing.osm_id) AS road_num, crossing.osm_id AS cross_osm_id, link.geom AS link_geom, crossing.geom AS cross_geom
FROM jolie_uni2.osm_crossing crossing
JOIN jolie_uni2.osm_sw link ON ST_Intersects(crossing.geom, link.geom)
WHERE ST_Length(link.geom) < 12
ORDER BY link.osm_id -- 56

SELECT link.osm_id AS link_osm_id, ROW_NUMBER() OVER (PARTITION BY link.osm_id ORDER BY crossing.osm_id) AS road_num, crossing.osm_id AS cross_osm_id, link.geom AS link_geom, crossing.geom AS cross_geom
FROM jolie_uni2.osm_crossing crossing
JOIN jolie_uni2.osm_footway_null link ON ST_Intersects(crossing.geom, link.geom)
WHERE ST_Length(link.geom) < 12
ORDER BY link.osm_id -- 55

CREATE TABLE jolie_uni2.osm_connlink_all AS
  (	SELECT DISTINCT link.osm_id AS link_osm_id, 'footway=sidewalk' AS label, link.geom AS link_geom
	FROM jolie_uni2.osm_crossing crossing
	JOIN jolie_uni2.osm_sw link ON ST_Intersects(crossing.geom, link.geom)
	WHERE ST_Length(link.geom) < 12 ) -- 41
	UNION ALL
 (  SELECT DISTINCT link.osm_id AS link_osm_id, 'footway IS NULL' AS label, link.geom AS link_geom
	FROM jolie_uni2.osm_crossing crossing
	JOIN jolie_uni2.osm_footway_null link ON ST_Intersects(crossing.geom, link.geom)
	WHERE ST_Length(link.geom) < 12 ) --93



---- STEP 4: deal with general case of sidewalk

-- In this code, we filter:
-- 1. the road buffer and the sidewalk buffer overlap
-- 2. the road and the sidewalk are parallel to each other (between 0-30 or 165/195 or 330-360 degree)
-- 3. in case where the sidewalk.geom looking at more than 2 road.geom at the same time, we need to choose the one that have the closest distance
--    from the midpoint of the sidewalk to the midpoint of the road
-- 4. Ignore those roads that are already entrance, connlink table

CREATE TABLE jolie_uni2.confation_sidewalk AS
WITH ranked_roads AS (
	SELECT
	  sidewalk.osm_id AS osm_id,
	  big_road.og_objectid AS arnold_objectid,
	  sidewalk.geom AS osm_geom,
	  ST_LineSubstring( big_road.geom, LEAST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(sidewalk.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))), GREATEST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(sidewalk.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))) ) AS seg_geom,
	  -- rank this based on the distance of the midpoint of the sidewalk to the midpoint of the road
	  ROW_NUMBER() OVER (
	  	PARTITION BY sidewalk.geom
	  	ORDER BY ST_distance( 
	  				ST_LineSubstring( big_road.geom,
	  								  LEAST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(sidewalk.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))),
	  								  GREATEST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(sidewalk.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))) ),
	  				sidewalk.geom )
	  	) AS RANK
	FROM jolie_uni2.osm_sw sidewalk
	JOIN jolie_uni2.arnold_roads big_road ON ST_Intersects(ST_Buffer(sidewalk.geom, 5), ST_Buffer(big_road.geom, 18))
	WHERE 
	  (  ABS(DEGREES(ST_Angle(ST_LineSubstring( big_road.geom, LEAST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(sidewalk.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))), GREATEST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(sidewalk.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))) ), sidewalk.geom))) BETWEEN 0 AND 10 -- 0 
		 OR ABS(DEGREES(ST_Angle(ST_LineSubstring( big_road.geom, LEAST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(sidewalk.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))), GREATEST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(sidewalk.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))) ), sidewalk.geom))) BETWEEN 170 AND 190 -- 180
		 OR ABS(DEGREES(ST_Angle(ST_LineSubstring( big_road.geom, LEAST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(sidewalk.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))), GREATEST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(sidewalk.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))) ), sidewalk.geom))) BETWEEN 350 AND 360 ) -- 360
    )
SELECT
	  osm_id,
	  arnold_objectid,
	  osm_geom,
	  seg_geom AS arnold_geom
FROM
	  ranked_roads
WHERE
	  rank = 1
	  AND ( osm_id NOT IN (
 				SELECT link.osm_id FROM jolie_uni2.confation_connlink link 
			    UNION ALL
			    SELECT entrance.osm_id FROM jolie_uni2.confation_entrances entrance)	
 	      ); -- 66
	 

CREATE INDEX sidwalk_sidwalk_geom ON jolie_uni2.confation_sidewalk USING GIST (osm_geom);
CREATE INDEX sidwalk_arnold_geom ON jolie_uni2.confation_sidewalk USING GIST (arnold_geom);
	


---- STEP 5: Dealing with edges
	-- assumption: edge will have it start and end point connectected to sidewalk. We will use the sidewalk table to identify our sidewalk edges
CREATE TABLE jolie_uni2.confation_sw_edges (
	osm_id INT8,
	arnold_objectid1 INT8,
	arnold_objectid2 INT8,
	osm_geom GEOMETRY(LineString, 3857) )


INSERT INTO jolie_uni2.confation_sw_edges (osm_id, arnold_objectid1, arnold_objectid2, osm_geom)
	SELECT  edge.osm_id AS osm_id,
			centerline1.arnold_objectid AS arnold_objectid1,
			centerline1.arnold_objectid AS arnold_objectid2,
			edge.geom AS osm_geom
	FROM jolie_uni2.osm_sw edge
	JOIN jolie_uni2.confation_sidewalk centerline1 ON st_intersects(st_startpoint(edge.geom), centerline1.osm_geom)
	JOIN jolie_uni2.confation_sidewalk centerline2 ON st_intersects(st_endpoint(edge.geom), centerline2.osm_geom)
	WHERE   edge.geom NOT IN (
				SELECT sw.osm_geom FROM jolie_uni2.confation_sidewalk sw
				UNION ALL 
				SELECT link.osm_geom FROM jolie_uni2.confation_connlink link
				UNION ALL 
				SELECT entrance.osm_geom FROM jolie_uni2.confation_entrances entrance)
			AND ST_Equals(centerline1.osm_geom, centerline2.osm_geom) IS FALSE
			AND centerline1.arnold_objectid != centerline2.arnold_objectid -- 1
			
			
---- STEP 6: Dealing with osm_sw that is parallel with a conflated sidewalk

-- conflate into sidewalk if the segment is parallel to the sw, and have it end/start point intersect with another end/start point of the sidewalk
-- and the arnold_objectid of the conflated sidewalk must be the same as the road's og_objectid where the segment is looking at
INSERT INTO jolie_uni2.confation_sidewalk(osm_id, arnold_objectid, osm_geom, arnold_geom)
WITH ranked_road AS (
	SELECT DISTINCT osm_sw.osm_id, sidewalk.arnold_objectid, osm_sw.geom AS osm_geom,
		            ST_LineSubstring( big_road.geom, LEAST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(osm_sw.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(osm_sw.geom), big_road.geom))), GREATEST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(osm_sw.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(osm_sw.geom), big_road.geom))) ) AS seg_geom,
					  -- rank this based on the distance of the midpoint of the sidewalk to the midpoint of the road
					  ROW_NUMBER() OVER (
					  	PARTITION BY osm_sw.geom
					  	ORDER BY ST_distance( 
					  				ST_LineSubstring( big_road.geom,
					  								  LEAST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(osm_sw.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(osm_sw.geom), big_road.geom))),
					  								  GREATEST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(osm_sw.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(osm_sw.geom), big_road.geom))) ),
					  				osm_sw.geom )
					  	) AS RANK
	FROM jolie_uni2.osm_sw
	JOIN jolie_uni2.confation_sidewalk sidewalk
	ON 	ST_Intersects(st_startpoint(sidewalk.osm_geom), st_startpoint(osm_sw.geom))
		OR ST_Intersects(st_startpoint(sidewalk.osm_geom), st_endpoint(osm_sw.geom))
		OR ST_Intersects(st_endpoint(sidewalk.osm_geom), st_startpoint(osm_sw.geom))
		OR ST_Intersects(st_endpoint(sidewalk.osm_geom), st_endpoint(osm_sw.geom))
	JOIN jolie_uni2.arnold_roads big_road
	ON ST_Intersects(ST_Buffer(osm_sw.geom, 5), ST_Buffer(osm_sw.geom, 18))
	WHERE osm_sw.geom NOT IN (
			SELECT sidewalk.osm_geom FROM jolie_uni2.confation_sidewalk sidewalk
		    UNION ALL
		    SELECT link.osm_geom FROM jolie_uni2.confation_connlink link 
		    UNION ALL
		    SELECT entrance.osm_geom FROM jolie_uni2.confation_entrances entrance
		    UNION ALL
		    SELECT edge.osm_geom FROM jolie_uni2.confation_sw_edges edge )
		  AND ( -- specify that the segment should be PARALLEL TO our conflated sidewalk
				ABS(DEGREES(ST_Angle(sidewalk.osm_geom, osm_sw.geom))) BETWEEN 0 AND 10 -- 0 
			    OR ABS(DEGREES(ST_Angle(sidewalk.osm_geom, osm_sw.geom))) BETWEEN 170 AND 190 -- 180
			    OR ABS(DEGREES(ST_Angle(sidewalk.osm_geom, osm_sw.geom))) BETWEEN 350 AND 360  ) -- 360 
		 AND big_road.og_objectid = sidewalk.arnold_objectid
	)
	SELECT osm_id, arnold_objectid, osm_geom, seg_geom AS arnold_geom
	FROM ranked_road
	WHERE RANK = 1

			
			


-- checkpoint: see what is there in conflation tables
WITH conf_table AS (
		SELECT CAST(sidewalk.osm_id AS varchar(75)) AS id, sidewalk.osm_geom, 'sidewalk' AS label FROM jolie_uni2.confation_sidewalk sidewalk
	    UNION ALL
	    SELECT CAST(link.osm_id AS varchar(75)) AS id, link.osm_geom, 'link' AS label FROM jolie_uni2.confation_connlink link 
	    UNION ALL
	    SELECT CAST(crossing.osm_id AS varchar(75)) AS id, crossing.osm_geom, 'crossing' AS label FROM jolie_uni2.confation_crossing crossing
	    UNION ALL
	    SELECT CAST(edge.osm_id AS varchar(75)) AS id, edge.osm_geom, 'edge' AS label FROM jolie_uni2.confation_sw_edges edge
	    UNION ALL
	    SELECT CAST(entrance.osm_id AS varchar(75)) AS id, entrance.osm_geom, 'entrance' AS label FROM jolie_uni2.confation_entrances entrance
	    )
SELECT CAST(sw.osm_id AS varchar(75)) AS id, sw.geom, 'not conflated' AS label
FROM jolie_uni2.osm_sw sw
LEFT JOIN conf_table ON sw.geom = conf_table.osm_geom
WHERE conf_table.osm_geom IS NULL  --65



--------------------------------------------
		/** WEIRD CASES **/
--------------------------------------------



-- create a table of weird cases
CREATE TABLE jolie_uni2.weird_case AS
	WITH conf_table AS (
			SELECT CAST(sidewalk.osm_id AS varchar(75)) AS id, sidewalk.osm_geom, 'sidewalk' AS label FROM jolie_uni2.confation_sidewalk sidewalk
		    UNION ALL
		    SELECT CAST(link.osm_id AS varchar(75)) AS id, link.osm_geom, 'link' AS label FROM jolie_uni2.confation_connlink link 
		    UNION ALL
		    SELECT CAST(crossing.osm_id AS varchar(75)) AS id, crossing.osm_geom, 'crossing' AS label FROM jolie_uni2.confation_crossing crossing
		    UNION ALL
		    SELECT CAST(edge.osm_id AS varchar(75)) AS id, edge.osm_geom, 'edge' AS label FROM jolie_uni2.confation_sw_edges edge
		    UNION ALL
	    	SELECT CAST(entrance.osm_id AS varchar(75)) AS id, entrance.osm_geom, 'entrance' AS label FROM jolie_uni2.confation_entrances entrance
		    )
	SELECT sw.osm_id, sw.geom
	FROM jolie_uni2.osm_sw sw
	LEFT JOIN conf_table ON sw.geom = conf_table.osm_geom
	WHERE conf_table.osm_geom IS NULL

-- Split the weird case geom by the vertex
CREATE TABLE jolie_uni2.weird_case_seg AS
	WITH segments AS (
		SELECT osm_id,
		       row_number() OVER (PARTITION BY osm_id ORDER BY osm_id, (pt).path)-1 AS segment_number,
		       (ST_MakeLine(lag((pt).geom, 1, NULL) OVER (PARTITION BY osm_id ORDER BY osm_id, (pt).path), (pt).geom)) AS geom
		FROM (SELECT osm_id, ST_DumpPoints(geom) AS pt FROM jolie_uni2.weird_case) AS dumps )
	SELECT * FROM segments WHERE geom IS NOT NULL;



---- STEP 1: deal with link ----
CREATE TEMP TABLE temp_weird_case_connlink AS
	WITH connlink_rn AS 
		(SELECT DISTINCT ON (link.osm_id, link.segment_number, crossing.arnold_objectid)  link.osm_id AS osm_id, link.segment_number, crossing.arnold_objectid AS arnold_objectid, link.geom AS osm_geom, crossing.osm_geom AS cross_geom
	    FROM jolie_uni2.confation_crossing crossing
	    JOIN jolie_uni2.weird_case_seg link
	    ON ST_Intersects(crossing.osm_geom, st_startpoint(link.geom)) OR ST_Intersects(crossing.osm_geom, st_endpoint(link.geom))
	    WHERE ST_length(link.geom) < 12)
	SELECT osm_id, segment_number, ROW_NUMBER() OVER (PARTITION BY osm_id ORDER BY arnold_objectid) AS road_num, arnold_objectid, osm_geom
	FROM connlink_rn  -- 2


DROP TABLE temp_weird_case_sw
CREATE TEMPORARY TABLE temp_weird_case_sw AS
	WITH ranked_roads AS (
		SELECT
		  sidewalk.osm_id AS osm_id,
		  big_road.og_objectid AS arnold_objectid,
		  sidewalk.geom AS osm_geom,
		  sidewalk.segment_number AS segment_number,
		  -- the road segments that the sidewalk is conflated to
		  ST_LineSubstring( big_road.geom, LEAST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(sidewalk.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))), GREATEST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(sidewalk.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))) ) AS seg_geom,
		  -- rank this based on the distance of the midpoint of the sidewalk to the midpoint of the road
		  ROW_NUMBER() OVER (
		  	PARTITION BY sidewalk.geom
		  	ORDER BY ST_distance( 
		  				ST_LineSubstring( big_road.geom,
		  								  LEAST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(sidewalk.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))),
		  								  GREATEST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(sidewalk.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))) ),
		  				sidewalk.geom )
		  	) AS RANK
		FROM jolie_uni2.weird_case_seg sidewalk
		JOIN jolie_uni2.arnold_roads big_road ON ST_Intersects(ST_Buffer(sidewalk.geom, 5), ST_Buffer(big_road.geom, 18))
		WHERE 
		  (  ABS(DEGREES(ST_Angle(ST_LineSubstring( big_road.geom, LEAST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(sidewalk.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))), GREATEST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(sidewalk.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))) ), sidewalk.geom))) BETWEEN 0 AND 10 -- 0 
			 OR ABS(DEGREES(ST_Angle(ST_LineSubstring( big_road.geom, LEAST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(sidewalk.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))), GREATEST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(sidewalk.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))) ), sidewalk.geom))) BETWEEN 170 AND 190 -- 180
			 OR ABS(DEGREES(ST_Angle(ST_LineSubstring( big_road.geom, LEAST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(sidewalk.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))), GREATEST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(sidewalk.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))) ), sidewalk.geom))) BETWEEN 350 AND 360 ) -- 360
	      AND sidewalk.osm_id NOT IN (SELECT osm_id FROM temp_weird_case_connlink)
			 )
	SELECT
		  osm_id,
		  segment_number,
		  arnold_objectid,
		  osm_geom,
		  seg_geom AS arnold_geom
	FROM
		  ranked_roads
	WHERE
		  rank = 1
	ORDER BY osm_id, segment_number; --51

SELECT * FROM temp_weird_case_sw
ORDER BY osm_id, segment_number


SELECT * FROM jolie_uni2.arnold_roads ar 

-- deal with segments that have a segment_number in between the min and max segment_number of the 
INSERT INTO temp_weird_case_sw (osm_id, segment_number, osm_geom, arnold_objectid)
	WITH min_max_segments AS (
	  SELECT osm_id, MIN(segment_number) AS min_segment, MAX(segment_number) AS max_segment, arnold_objectid
	  FROM temp_weird_case_sw
	  GROUP BY osm_id, arnold_objectid
	)
	SELECT seg_sw.osm_id, seg_sw.segment_number, seg_sw.geom, mms.arnold_objectid
	FROM jolie_uni2.weird_case_seg seg_sw
	JOIN min_max_segments mms ON seg_sw.osm_id = mms.osm_id
	WHERE seg_sw.segment_number BETWEEN mms.min_segment AND mms.max_segment
		  AND (seg_sw.osm_id, seg_sw.segment_number) NOT IN (
		  		SELECT osm_id, segment_number
		  		FROM temp_weird_case_sw
		  )
	ORDER BY seg_sw.osm_id, seg_sw.segment_number; --11

-- checkpoint
-- for the case where a osm_id is looking at 2 different arnold_objectid,
-- it will look at segments that are not conflated, uptil the first segment that intersects with the link
--SELECT DISTINCT seg.osm_id, seg.segment_number
--FROM jolie_uni2.weird_case_seg seg
--JOIN jolie_uni2.confation_connlink link ON ST_Intersects(link.osm_geom, seg.geom)
--WHERE (seg.osm_id, seg.segment_number) NOT IN (
--		SELECT osm_id, segment_number
--		FROM temp_weird_case_sw
--	)
--ORDER BY seg.osm_id, seg.segment_number


-- see how much segments conflated
WITH partial_length AS (
	  SELECT osm_id, arnold_objectid,  MIN(segment_number) AS min_segment, MAX(segment_number) AS max_segment, SUM(ST_Length(osm_geom)) AS partial_length, st_linemerge(ST_union(osm_geom), TRUE) AS geom
	  FROM temp_weird_case_sw
	  GROUP BY osm_id,  arnold_objectid
	)
	SELECT sw.osm_id, pl.min_segment, pl.max_segment, pl.arnold_objectid, pl.geom AS seg_geom, sw.geom AS osm_geom, pl.partial_length/ST_Length(sw.geom) AS percent_conflated
	FROM jolie_uni2.weird_case sw
	JOIN partial_length pl ON sw.osm_id = pl.osm_id; 



-- see how the rest of the segments that cannot be conflated look
WITH conf_seg AS (
	  SELECT osm_id, arnold_objectid,  MIN(segment_number) AS min_segment, MAX(segment_number) AS max_segment, st_linemerge(ST_union(osm_geom), TRUE) AS geom
	  FROM temp_weird_case_sw
	  GROUP BY osm_id,  arnold_objectid
	)
	SELECT seg.osm_id, seg.segment_number, conf_seg.min_segment, conf_seg.max_segment, conf_seg.geom AS conf_geom, seg.geom AS seg_geom, st_length(seg.geom), conf_seg.arnold_objectid
	FROM jolie_uni2.weird_case_seg seg
	JOIN conf_seg
	ON seg.osm_id = conf_seg.osm_id
	WHERE seg.segment_number NOT BETWEEN min_segment AND max_segment
		  AND (seg.osm_id, seg.segment_number) NOT IN (SELECT osm_id, segment_number FROM temp_weird_case_sw)
	ORDER BY seg.osm_id, conf_seg.min_segment, seg.segment_number; 



