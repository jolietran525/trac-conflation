--------------------------------------------
		/** BOUNDING BOX **/
--------------------------------------------

---------- OSM in u-district ------------

-- highway = footway, footway = sidewalk
CREATE table jolie_uni1.osm_sw AS (
	SELECT *
	FROM planet_osm_line
	WHERE	highway = 'footway' AND
			tags -> 'footway' = 'sidewalk' AND 
			way && st_setsrid( st_makebox2d( st_makepoint(-13615706,6049150), st_makepoint(-13614794,6050673)), 3857) ); -- 184

ALTER TABLE jolie_uni1.osm_sw RENAME COLUMN way TO geom;


-- points
CREATE table jolie_uni1.osm_point AS (
	SELECT *
	FROM planet_osm_point
	WHERE
			way && st_setsrid( st_makebox2d( st_makepoint(-13615706,6049150), st_makepoint(-13614794,6050673)), 3857) ); -- 1452

ALTER TABLE jolie_uni1.osm_point RENAME COLUMN way TO geom;

-- highway = footway, footway = crossing
CREATE TABLE jolie_uni1.osm_crossing AS (
	SELECT *
	FROM planet_osm_line
	WHERE   highway = 'footway' AND 
			tags -> 'footway' = 'crossing' AND 
			way && st_setsrid( st_makebox2d( st_makepoint(-13615706,6049150), st_makepoint(-13614794,6050673)), 3857) ); -- 116

ALTER TABLE jolie_uni1.osm_crossing RENAME COLUMN way TO geom;


-- highway = footway, footway IS NULL OR footway not sidewalk/crossing
CREATE TABLE jolie_uni1.osm_footway_null AS (
	SELECT *
	FROM planet_osm_line
	WHERE 	highway = 'footway' AND 
			(tags -> 'footway' IS NULL OR 
			tags -> 'footway' NOT IN ('sidewalk', 'crossing'))  AND
			way && st_setsrid( st_makebox2d( st_makepoint(-13615706,6049150), st_makepoint(-13614794,6050673)), 3857)  ); -- 910
		
ALTER TABLE jolie_uni1.osm_footway_null RENAME COLUMN way TO geom;


--------- ARNOLD in u-district ----------
CREATE TABLE jolie_uni1.arnold_roads AS (
	SELECT *
	FROM arnold.wapr_linestring 
	WHERE geom && st_setsrid( st_makebox2d( st_makepoint(-13615706,6049150), st_makepoint(-13614794,6050673)), 3857)
	ORDER BY routeid, beginmeasure, endmeasure); -- 23





--------------------------------------------
			/* CONFLATION */
--------------------------------------------

--------- STEP 1: break down the main road whenever it intersects with another main road ---------

-- This code creates a new table named segment_test by performing the following steps:
	-- Define intersection_points table which finds distinct intersection points between different geometries in the jolie_uni1.arnold_roads table.
	-- Performs a select query that joins the arnold.wapr_udistrict table (a) with the intersection_points CTE (b) using object IDs and route IDs. It collects all the intersection geometries (ST_collect(b.geom)) for each object ID and route ID.
	-- Finally, it splits the geometries in a.geom using the collected intersection geometries (ST_Split(a.geom, ST_collect(b.geom))). The result is a set of individual linestrings obtained by splitting the original geometries.
	-- The resulting linestrings are grouped by object ID, route ID, and original geometry (a.objectid, a.routeid, a.geom) and inserted into the jolie_uni1.arnold_segments_collection table.
CREATE TABLE jolie_uni1.arnold_segments_collection AS
	WITH intersection_points AS (
	  SELECT DISTINCT m1.objectid objectid, m1.og_objectid og_objectid, m1.routeid routeid, m1.beginmeasure beginmeasure, m1.endmeasure endmeasure,
	  		   ( ST_DumpPoints(ST_Intersection(m1.geom, m2.geom)) ).geom AS geom
	  FROM jolie_uni1.arnold_roads m1
	  JOIN jolie_uni1.arnold_roads m2
	  ON ST_Intersects(m1.geom, m2.geom) AND ST_Equals(m1.geom,m2.geom) IS FALSE
	   )
	SELECT
	  a.objectid, a.og_objectid, a.routeid, a.beginmeasure, a.endmeasure, ST_collect(b.geom), ST_Split(a.geom, ST_Collect(b.geom))
	FROM
	  jolie_uni1.arnold_roads AS a
	JOIN
	  intersection_points AS b ON a.objectid = b.objectid -- ST_intersects(a.geom, ST_Snap(b.geom, a.geom, ST_Distance(b.geom, a.geom))) 
	GROUP BY
	  a.objectid,
	  a.og_objectid,
	  a.routeid,
	  a.beginmeasure,
	  a.endmeasure,
	  a.geom;

-- create a table that pull the data from the segment_test table, convert it into linestring instead leaving it as a collection
CREATE TABLE jolie_uni1.arnold_segments_line AS
	SELECT objectid, og_objectid, routeid, beginmeasure, endmeasure, (ST_Dump(st_split)).geom::geometry(LineString, 3857) AS geom
	FROM jolie_uni1.arnold_segments_collection
	ORDER BY routeid, beginmeasure, endmeasure;

-- Create a geom index
CREATE INDEX segments_line_geom ON jolie_uni1.arnold_segments_line USING GIST (geom);
CREATE INDEX sw_geom ON jolie_uni1.osm_sw USING GIST (geom);
CREATE INDEX crossing_geom ON jolie_uni1.osm_crossing USING GIST (geom);
CREATE INDEX point_geom ON jolie_uni1.osm_point USING GIST (geom);
CREATE INDEX footway_null_geom ON jolie_uni1.osm_footway_null USING GIST (geom);



--------- STEP 2: identify matching criteria between sidewalk and arnold ---------
-- since the arnold and the OSM datasets don't have any common attributes or identifiers, and their content represents
-- different aspects of the street network (sidewalk vs main roads), we are going to rely on the geomtry properties and
-- spatial relationships to find potential matches. So, we want:
-- 1. buffering
-- 2. intersection with buffer of the road segment
-- 3. parallel

-- check point 2.1: how many sidewalks are there
SELECT *
FROM jolie_uni1.osm_sw sidewalk; -- there ARE 184 sidewalks

-- check point 2.2: how many road segments are there
SELECT *
FROM jolie_uni1.arnold_segments_line; -- there ARE 59 segments

-- In this code, we filter:
-- 1. the road buffer and the sidewalk buffer overlap
-- 2. the road and the sidewalk are parallel to each other (between 0-30 or 165/195 or 330-360 degree)
-- 3. in case where the sidewalk.geom looking at more than 2 road.geom at the same time, we need to choose the one that have the closest distance
--    from the midpoint of the sidewalk to the midpoint of the road
-- 4. Ignore those roads that are smaller than 10 meters
-- Create a big_sw table which contains 65 sidewalk segments that are greater 10 meters and parallel to the road. This is pretty solid.


-- new one
CREATE TABLE jolie_conflation_uni1.big_sw AS
WITH ranked_roads AS (
	SELECT
	  sidewalk.osm_id AS osm_id,
	  big_road.routeid AS arnold_routeid,
	  big_road.beginmeasure AS arnold_beginmeasure,
	  big_road.endmeasure AS arnold_endmeasure,
	  sidewalk.geom AS osm_geom,
	  ST_LineSubstring( big_road.geom, LEAST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(sidewalk.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))), GREATEST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(sidewalk.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))) ) AS seg_geom,
	  -- calculate the coverage of sidewalk within the buffer of the road
	  ST_Length(ST_Intersection(sidewalk.geom, ST_Buffer(ST_LineSubstring( big_road.geom, LEAST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))), GREATEST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))) ), 18))) / ST_Length(sidewalk.geom) AS sidewalk_coverage_bigroad,
	  -- rank this based on the distance of the midpoint of the sidewalk to the midpoint of the road
	  ROW_NUMBER() OVER (
	  	PARTITION BY sidewalk.geom
	  	ORDER BY ST_distance( 
	  				ST_LineSubstring( big_road.geom,
	  								  LEAST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(sidewalk.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))),
	  								  GREATEST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(sidewalk.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))) ),
	  				sidewalk.geom )
	  	) AS RANK
	FROM jolie_uni1.osm_sw sidewalk
	JOIN jolie_uni1.arnold_roads big_road ON ST_Intersects(ST_Buffer(sidewalk.geom, 5), ST_Buffer(big_road.geom, 15))
	WHERE 
	  (ABS(DEGREES(ST_Angle(ST_LineSubstring( big_road.geom, LEAST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(sidewalk.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))), GREATEST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(sidewalk.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))) ), sidewalk.geom))) BETWEEN 0 AND 10 -- 0 
		 OR ABS(DEGREES(ST_Angle(ST_LineSubstring( big_road.geom, LEAST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(sidewalk.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))), GREATEST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(sidewalk.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))) ), sidewalk.geom))) BETWEEN 170 AND 190 -- 180
		 OR ABS(DEGREES(ST_Angle(ST_LineSubstring( big_road.geom, LEAST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(sidewalk.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))), GREATEST(ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_startpoint(sidewalk.geom), big_road.geom)) , ST_LineLocatePoint(big_road.geom, ST_ClosestPoint(st_endpoint(sidewalk.geom), big_road.geom))) ), sidewalk.geom))) BETWEEN 350 AND 360 ) -- 360
	  AND (ST_Length(sidewalk.geom) > 8) )
SELECT DISTINCT
	  osm_id,
	  arnold_routeid,
	  arnold_beginmeasure,
	  arnold_endmeasure,
	  osm_geom,
	  seg_geom AS arnold_geom
FROM
	  ranked_roads
WHERE
	  rank = 1;
	 
CREATE INDEX big_sw_sidwalk_geom ON jolie_conflation_uni1.big_sw USING GIST (osm_geom);
CREATE INDEX big_sw_arnold_geom ON jolie_conflation_uni1.big_sw USING GIST (arnold_geom);



-------------- STEP 3: How to deal with the rest of the footway = sidewalk segments? Possibilities are: edges, connecting link --------------
-- check point 3.1: how many sidewalk segments left, there are edges and link 
SELECT *
FROM jolie_uni1.osm_sw sidewalk
WHERE sidewalk.geom NOT IN (
	SELECT big_sw.osm_geom
	FROM jolie_conflation_uni1.big_sw big_sw); --119
	

	
	
---- STEP 3.1: Dealing with edges
	-- assumption: edge will have it start and end point connectected to sidewalk. We will use the big_sw table to identify our sidewalk edges
CREATE TABLE jolie_conflation_uni1.sw_edges (
	osm_id INT8,
	arnold_routeid1 VARCHAR(75),
	arnold_beginmeasure1 FLOAT8,
	arnold_endmeasure1 FLOAT8,
	arnold_routeid2 VARCHAR(75),
	arnold_beginmeasure2 FLOAT8,
	arnold_endmeasure2 FLOAT8,
	osm_geom GEOMETRY(LineString, 3857)
)


INSERT INTO jolie_conflation_uni1.sw_edges (osm_id, arnold_routeid1, arnold_beginmeasure1, arnold_endmeasure1, arnold_routeid2, arnold_beginmeasure2, arnold_endmeasure2, osm_geom)
	SELECT  edge.osm_id AS osm_id,
			centerline1.arnold_routeid AS arnold_routeid1,
			centerline1.arnold_beginmeasure AS arnold_beginmeasure1,
			centerline1.arnold_endmeasure AS arnold_endmeasure1,
			centerline2.arnold_routeid AS arnold_routeid2,
			centerline2.arnold_beginmeasure AS arnold_beginmeasure2,
			centerline2.arnold_endmeasure AS arnold_endmeasure2,
			edge.geom AS osm_geom
	FROM jolie_uni1.osm_sw edge
	JOIN jolie_conflation_uni1.big_sw centerline1 ON st_intersects(st_startpoint(edge.geom), centerline1.osm_geom)
	JOIN jolie_conflation_uni1.big_sw centerline2 ON st_intersects(st_endpoint(edge.geom), centerline2.osm_geom)
	WHERE   edge.geom NOT IN (
				SELECT sw.osm_geom
				FROM jolie_conflation_uni1.big_sw sw)
			AND ST_Equals(centerline1.osm_geom, centerline2.osm_geom) IS FALSE --2
			
SELECT sw.*, point.tags, point.geom
FROM jolie_conflation_uni1.big_sw sw
JOIN jolie_uni1.osm_point point
ON ST_Intersects(st_startpoint(sw.osm_geom), point.geom) OR ST_Intersects(st_endpoint(sw.osm_geom), point.geom)
			
---- STEP 3.2: Dealing with entrances
	-- assumption: entrances are small segments that intersect with the sidewalk on one end and intersect with a point that have a tag of entrance=* or wheelchair=*
	
-- create an entrance table
--CREATE TABLE jolie_conflation_uni1.entrances AS
--	SELECT entrance.osm_id, sidewalk.osm_id AS sidewalk_id, entrance.geom AS osm_geom, point.tags, point.geom
--	FROM jolie_uni1.osm_point point
--	JOIN (	SELECT *
--			FROM jolie_uni1.osm_sw sidewalk
--			WHERE sidewalk.geom NOT IN (
--					SELECT osm_geom
--					FROM jolie_conflation_uni1.big_sw ) AND 
--				  sidewalk.geom NOT IN (
--					SELECT osm_geom
--					FROM jolie_conflation_uni1.sw_edges )  ) AS entrance
--	ON ST_intersects(entrance.geom, point.geom)
--	JOIN jolie_conflation_uni1.big_sw sidewalk ON ST_Intersects(entrance.geom, sidewalk.osm_geom)
--	WHERE point.tags -> 'kerb' IS NULL
--			AND entrance.geom NOT IN (
--				SELECT osm_geom
--				FROM jolie_conflation_uni1.connlink
--			)
			
			
CREATE TABLE jolie_conflation_uni1.entrances AS
	SELECT entrance.osm_id, sidewalk.osm_id AS sidewalk_id, entrance.geom AS osm_geom
	FROM jolie_uni1.osm_point point
	JOIN (	SELECT *
			FROM jolie_uni1.osm_sw sidewalk
			WHERE sidewalk.geom NOT IN (
					SELECT osm_geom
					FROM jolie_conflation_uni1.big_sw ) AND 
				  sidewalk.geom NOT IN (
					SELECT osm_geom
					FROM jolie_conflation_uni1.sw_edges )  ) AS entrance
	ON ST_intersects(entrance.geom, point.geom)
	JOIN jolie_conflation_uni1.big_sw sidewalk ON ST_Intersects((entrance.geom), sidewalk.osm_geom)
	WHERE point.tags -> 'entrance' IS NOT NULL 	
			

---- STEP 3.3: Dealing with crossing
	-- assumption: all of the crossing are referred to as footway=crossing

-- check point: see how many crossing are there 
SELECT DISTINCT crossing.osm_id, crossing.geom
FROM jolie_uni1.osm_crossing crossing -- 60

CREATE TABLE jolie_conflation_uni1.crossing (osm_id, arnold_routeid, arnold_beginmeasure, arnold_endmeasure, osm_geom) AS
	SELECT crossing.osm_id AS osm_id, road.routeid AS arnold_routeid, road.beginmeasure AS arnold_beginmeasure, road.endmeasure arnold_endmeasure, crossing.geom AS osm_geom 
	FROM jolie_uni1.osm_crossing crossing
	JOIN jolie_uni1.arnold_segments_line road ON ST_Intersects(crossing.geom, road.geom)
-- note, there is one special case that is not joined in this table cuz it is not intersecting with any roads: osm_id 929628172. This crossing segment has the access=no

	
	
	
---- STEP 3.4: Dealing with connecting link
	-- assumption 1: a link connects the sidewalk to the crossing
	-- assumption 2: OR a link connects the sidewalk esge to the crossing
	-- note: a link might or might not have a footway='sidewalk' tag

	
-- check point: segments (footway=sidewalk) intersects crossing and not yet in conflation table --> link
SELECT crossing.osm_id AS cross_id, sw.geom AS link_geom, crossing.osm_geom AS cross_geom, sw.osm_id AS link_id
FROM jolie_conflation_uni1.crossing crossing
JOIN jolie_uni1.osm_sw sw ON ST_Intersects(crossing.osm_geom, sw.geom)
WHERE sw.geom NOT IN (
		SELECT osm_geom
		FROM jolie_conflation_uni1.big_sw ) AND
	  sw.geom NOT IN (
		SELECT osm_geom
		FROM jolie_conflation_uni1.sw_edges ) AND
	  ST_Length(sw.geom) < 10 -- leaving the two special cases OUT: osm_id = 490774566, 475987407
ORDER BY link_id



CREATE TABLE jolie_conflation_uni1.connlink (
	osm_id INT8,
	arnold_routeid1 VARCHAR(75), 
	arnold_beginmeasure1 FLOAT8,
	arnold_endmeasure1 FLOAT8,
	arnold_routeid2 VARCHAR(75),
	arnold_beginmeasure2 FLOAT8,
	arnold_endmeasure2 FLOAT8,
	osm_geom GEOMETRY(LineString, 3857)
)


-- STEP 3.4.1: Deal with links (footway = sidewalk) that are connected to crossing and not yet in the big_sw table
INSERT INTO jolie_conflation_uni1.connlink (osm_id, arnold_routeid1, arnold_beginmeasure1, arnold_endmeasure1, arnold_routeid2, arnold_beginmeasure2, arnold_endmeasure2, osm_geom)
WITH link_not_distinct AS (
    SELECT link_id, arnold_routeid, arnold_beginmeasure, arnold_endmeasure, cross_id, link_geom, ROW_NUMBER() OVER (PARTITION BY link_id ORDER BY cross_id) AS rn
    FROM
        (
            SELECT
                crossing.osm_id AS cross_id, crossing.arnold_routeid, crossing.arnold_beginmeasure, crossing.arnold_endmeasure, sw.geom AS link_geom, crossing.osm_geom AS cross_geom, sw.osm_id AS link_id
            FROM
                jolie_conflation_uni1.crossing crossing
            JOIN
                jolie_uni1.osm_sw sw ON ST_Intersects(crossing.osm_geom, st_startpoint(sw.geom)) OR ST_Intersects(crossing.osm_geom, st_endpoint(sw.geom))
            WHERE
                sw.geom NOT IN (
                    SELECT osm_geom
                    FROM jolie_conflation_uni1.big_sw )
                AND sw.geom NOT IN (
					SELECT osm_geom
					FROM jolie_conflation_uni1.sw_edges )
                AND  ST_length(sw.geom) < 10
            ORDER BY
                link_id
        ) subquery
)
SELECT
    link_id AS osm_id,
    MAX(CASE WHEN rn = 1 THEN arnold_routeid END) AS arnold_routeid1,
    MAX(CASE WHEN rn = 1 THEN arnold_beginmeasure END) AS arnold_beginmeasure1,
    MAX(CASE WHEN rn = 1 THEN arnold_endmeasure END) AS arnold_endmeasure1,
    MAX(CASE WHEN rn = 2 THEN arnold_routeid END) AS arnold_routeid2,
    MAX(CASE WHEN rn = 2 THEN arnold_beginmeasure END) AS arnold_beginmeasure2,
    MAX(CASE WHEN rn = 2 THEN arnold_endmeasure END) AS arnold_endmeasure2,
    link_geom AS osm_geom
FROM
    link_not_distinct
GROUP BY
    link_id, link_geom ;



-- check point: how highway=footway and crossing (conflated) and sidewalk are connected?
SELECT link_crossing.link_id, link_crossing.cross_id, link_crossing.arnold_routeid, link_crossing.arnold_beginmeasure, link_crossing.arnold_endmeasure, ST_Length(link_crossing.link_geom), link_crossing.cross_geom, link_crossing.link_geom AS link_geom, ROW_NUMBER() OVER (PARTITION BY link_crossing.link_id ORDER BY link_crossing.cross_id) AS rn
FROM jolie_uni1.osm_sw sidewalk
JOIN (  SELECT link.osm_id AS link_id, crossing.osm_id AS cross_id, crossing.arnold_routeid, crossing.arnold_beginmeasure, crossing.arnold_endmeasure, crossing.osm_geom AS cross_geom, link.geom AS link_geom
		FROM jolie_uni1.osm_footway_null link
		JOIN jolie_conflation_uni1.crossing crossing
		ON ST_Intersects(link.geom, crossing.osm_geom)) AS link_crossing
ON ST_Intersects(sidewalk.geom, link_crossing.link_geom)
WHERE ST_Length(link_crossing.link_geom) < 10



-- STEP 3.4.2: deal with link that are not tagged as sidewalk/crossing
INSERT INTO jolie_conflation_uni1.connlink (osm_id, arnold_routeid1, arnold_beginmeasure1, arnold_endmeasure1, arnold_routeid2, arnold_beginmeasure2, arnold_endmeasure2, osm_geom)
WITH link_not_distinct AS (
SELECT link_crossing.link_id, link_crossing.cross_id, link_crossing.arnold_routeid, link_crossing.arnold_beginmeasure, link_crossing.arnold_endmeasure, ST_Length(link_crossing.link_geom), link_crossing.cross_geom, link_crossing.link_geom AS link_geom, ROW_NUMBER() OVER (PARTITION BY link_crossing.link_id ORDER BY link_crossing.cross_id) AS rn
FROM jolie_uni1.osm_sw sidewalk
JOIN (  SELECT link.osm_id AS link_id, crossing.osm_id AS cross_id, crossing.arnold_routeid, crossing.arnold_beginmeasure, crossing.arnold_endmeasure, crossing.osm_geom AS cross_geom, link.geom AS link_geom
		FROM jolie_uni1.osm_footway_null link
		JOIN jolie_conflation_uni1.crossing crossing
		ON ST_Intersects(link.geom, crossing.osm_geom)) AS link_crossing
ON ST_Intersects(sidewalk.geom, link_crossing.link_geom)
WHERE ST_Length(link_crossing.link_geom) < 10
)
SELECT
    link_id AS osm_id,
    MAX(CASE WHEN rn = 1 THEN arnold_routeid END) AS arnold_routeid1,
    MAX(CASE WHEN rn = 1 THEN arnold_beginmeasure END) AS arnold_beginmeasure1,
    MAX(CASE WHEN rn = 1 THEN arnold_endmeasure END) AS arnold_endmeasure1,
    MAX(CASE WHEN rn = 2 THEN arnold_routeid END) AS arnold_routeid2,
    MAX(CASE WHEN rn = 2 THEN arnold_beginmeasure END) AS arnold_beginmeasure2,
    MAX(CASE WHEN rn = 2 THEN arnold_endmeasure END) AS arnold_endmeasure2,
    link_geom AS osm_geom
FROM
    link_not_distinct
GROUP BY
    link_id, link_geom ;

 
 
-- checkpoint: see what is there in conflation tables
WITH conf_table AS (
		SELECT CAST(big_sw.osm_id AS varchar(75)) AS id, big_sw.osm_geom, 'sidewalk' AS label FROM jolie_conflation_uni1.big_sw big_sw
	    UNION ALL
	    SELECT CAST(link.osm_id AS varchar(75)) AS id, link.osm_geom, 'link' AS label FROM jolie_conflation_uni1.connlink link 
	    UNION ALL
	    SELECT CAST(crossing.osm_id AS varchar(75)) AS id, crossing.osm_geom, 'crossing' AS label FROM jolie_conflation_uni1.crossing crossing
	    UNION ALL
	    SELECT CAST(edge.osm_id AS varchar(75)) AS id, edge.osm_geom, 'edge' AS label FROM jolie_conflation_uni1.sw_edges edge
	    )
SELECT sw.geom
FROM jolie_uni1.osm_sw sw
LEFT JOIN conf_table ON sw.geom = conf_table.osm_geom
WHERE conf_table.osm_geom IS NULL
UNION ALL
SELECT arnold.geom
FROM jolie_uni1.arnold_roads arnold


SELECT count(*) FROM jolie_conflation_uni1.big_sw -- 65
SELECT count(*) FROM jolie_conflation_uni1.sw_edges -- 2
--SELECT count(*) FROM jolie_conflation_uni1.entrances --9
SELECT count(*) FROM jolie_conflation_uni1.connlink --68




----- STEP 4: Handle weird case:

-- create a table of weird cases
CREATE TABLE jolie_uni1.weird_case AS
	WITH conf_table AS (
			SELECT CAST(big_sw.osm_id AS varchar(75)) AS id, big_sw.osm_geom, 'sidewalk' AS label FROM jolie_conflation_uni1.big_sw big_sw
		    UNION ALL
		    SELECT CAST(link.osm_id AS varchar(75)) AS id, link.osm_geom, 'link' AS label FROM jolie_conflation_uni1.connlink link 
		    UNION ALL
		    SELECT CAST(crossing.osm_id AS varchar(75)) AS id, crossing.osm_geom, 'crossing' AS label FROM jolie_conflation_uni1.crossing crossing
		    UNION ALL
		    SELECT CAST(edge.osm_id AS varchar(75)) AS id, edge.osm_geom, 'edge' AS label FROM jolie_conflation_uni1.sw_edges edge
		    )
	SELECT sw.osm_id, sw.tags, sw.geom
	FROM jolie_uni1.osm_sw sw
	LEFT JOIN conf_table ON sw.geom = conf_table.osm_geom
	WHERE conf_table.osm_geom IS NULL

-- Split the weird case geom by the vertex
WITH vertices AS (   
  SELECT osm_id, (ST_DumpPoints(geom)).geom AS geom
  FROM jolie_uni1.weird_case
)  
SELECT  (ST_Dump(ST_Split(a.geom, ST_Collect(b.geom)))).geom::geometry(LineString, 3857) AS segment
FROM jolie_uni1.weird_case a
JOIN vertices b ON a.osm_id = b.osm_id
GROUP BY a.osm_id, a.geom;

-- conflate into big_sw if the segment is parallel to the sw, and have it end/start point intersect with another end/start point of the big_sw
-- and also the sum of the segment and the big_sw should be less than the length of the road that the big_sw correspond to

INSERT INTO jolie_conflation_uni1.big_sw(osm_id, arnold_routeid, arnold_beginmeasure, arnold_endmeasure, osm_geom, arnold_geom)
SELECT DISTINCT osm_sw.osm_id, big_sw.arnold_routeid, big_sw.arnold_beginmeasure, big_sw.arnold_endmeasure, osm_sw.geom AS osm_geom, big_sw.arnold_geom
FROM jolie_uni1.osm_sw
JOIN jolie_conflation_uni1.big_sw
ON 	ST_Intersects(st_startpoint(big_sw.osm_geom), st_startpoint(osm_sw.geom))
	OR ST_Intersects(st_startpoint(big_sw.osm_geom), st_endpoint(osm_sw.geom))
	OR ST_Intersects(st_endpoint(big_sw.osm_geom), st_startpoint(osm_sw.geom))
	OR ST_Intersects(st_endpoint(big_sw.osm_geom), st_endpoint(osm_sw.geom))
WHERE osm_sw.geom NOT IN (
		SELECT big_sw.osm_geom FROM jolie_conflation_uni1.big_sw big_sw
	    UNION ALL
	    SELECT link.osm_geom FROM jolie_conflation_uni1.connlink link 
	    UNION ALL
	    SELECT crossing.osm_geom FROM jolie_conflation_uni1.crossing crossing
	    UNION ALL
	    SELECT edge.osm_geom FROM jolie_conflation_uni1.sw_edges edge )
	  AND ( -- specify that the segment should be PARALLEL TO our conflated sidewalk
			ABS(DEGREES(ST_Angle(big_sw.osm_geom, osm_sw.geom))) BETWEEN 0 AND 10 -- 0 
		    OR ABS(DEGREES(ST_Angle(big_sw.osm_geom, osm_sw.geom))) BETWEEN 170 AND 190 -- 180
		    OR ABS(DEGREES(ST_Angle(big_sw.osm_geom, osm_sw.geom))) BETWEEN 350 AND 360  ) -- 360  
	  AND (ST_Length(osm_sw.geom) + ST_Length(big_sw.osm_geom) ) < ST_Length(big_sw.arnold_geom)




-- LIMITATION: defined number and buffer cannot accurately represent all the sidewalk scenarios
	-- TODO: buffer size when we look at how many lanes there are --> better size of buffering

