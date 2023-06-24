--------------------------------------------
/** BOUNDING BOX **/
-------------------------------------
---------- OSM in u-district ------------
-- Date: 20230616
create table osm_sidewalk_udistrict AS -- ONLY footway = sidewalk
(select *
from planet_osm_line
where 	highway = 'footway' and
		tags -> 'footway' = 'sidewalk' AND 
way && st_setsrid( st_makebox2d( st_makepoint(-13616401,6049782), st_makepoint(-13615688,6050649)), 3857))

-- SMALLER bbox in u-district for easier testing purpose
-- Date: 20230622
CREATE table osm_sidewalk_udistrict1 AS (-- ONLY footway = sidewalk
	SELECT *
	FROM planet_osm_line
	WHERE	highway = 'footway' AND
			tags -> 'footway' = 'sidewalk' AND 
	way && st_setsrid( st_makebox2d( st_makepoint(-13616323, 6049894), st_makepoint(-13615733, 6050671) ), 3857)	)

ALTER TABLE osm_sidewalk_udistrict1 RENAME COLUMN way TO geom;

create table osm_kerb_udistrict1 AS
(select *
from planet_osm_point
where  barrier = 'kerb' and
		-- tags -> 'footway' = 'sidewalk' AND 
way && st_setsrid( st_makebox2d( st_makepoint(-13616401,6049782), st_makepoint(-13615688,6050649)), 3857))


--------- ARNOLD in u-district ----------
-- Date: 20230616
create table arnold.wapr_udistrict as
(select *
from arnold.wapr_linestring 
where geom && st_setsrid( st_makebox2d( st_makepoint(-13616401,6049782), st_makepoint(-13615688,6050649)), 3857));

-- SMALLER bbox in u-district for easier testing purpose
-- Date: 20230622
create table arnold.wapr_udistrict1 as
(select *
from arnold.wapr_linestring 
where geom && st_setsrid( st_makebox2d( st_makepoint(-13616323, 6049894), st_makepoint(-13615733, 6050671)), 3857)
ORDER BY objectid, routeid);



--------------------------------------------
/* CONFLATION */
--------------------------------------------

--------- STEP 1: break down the main road whenever it intersects with another main road ---------

-- This code creates a new table named segment_test by performing the following steps:
	-- Define intersection_points table which finds distinct intersection points between different geometries in the arnold.wapr_udistrict1 table.
	-- Performs a select query that joins the arnold.wapr_udistrict table (a) with the intersection_points CTE (b) using object IDs and route IDs. It collects all the intersection geometries (ST_collect(b.geom)) for each object ID and route ID.
	-- Finally, it splits the geometries in a.geom using the collected intersection geometries (ST_Split(a.geom, ST_collect(b.geom))). The result is a set of individual linestrings obtained by splitting the original geometries.
	-- The resulting linestrings are grouped by object ID, route ID, and original geometry (a.objectid, a.routeid, a.geom) and inserted into the arnold.segment_test table.
-- Date: 20230622
CREATE TABLE arnold.segment_test AS
WITH intersection_points AS ( --
  SELECT DISTINCT m1.objectid oi1, m1.routeid ri1, ST_Intersection(m1.geom, m2.geom) AS geom
  FROM arnold.wapr_udistrict1 m1
  JOIN arnold.wapr_udistrict1 m2 ON ST_Intersects(m1.geom, m2.geom) AND m1.objectid <> m2.objectid
)
SELECT
  a.objectid, a.routeid, ST_collect(b.geom), ST_Split(a.geom, ST_collect(b.geom))
FROM
  arnold.wapr_udistrict1 AS a
JOIN
  intersection_points AS b ON a.objectid = b.oi1 AND a.routeid = b.ri1
GROUP BY
  a.objectid,
  a.routeid,
  a.geom;

-- create a table that pull the data from the segment_test table, convert it into linestring instead leaving it as a collection
CREATE TABLE arnold.segment_test_line AS
SELECT objectid, routeid, (ST_Dump(st_split)).geom::geometry(LineString, 3857) AS geom
FROM arnold.segment_test;

-- Create a geom index for segment_test_line and osm_sidewalk_udistrict1
CREATE INDEX segment_test_line_geom ON arnold.segment_test_line USING GIST (geom)
CREATE INDEX osm_sidewalk_udistrict1_geom ON osm_sidewalk_udistrict1 USING GIST (geom)

--------- STEP 2: identify matching criteria ---------
-- since the arnold and the OSM datasets don't have any common attributes or identifiers, and their content represents
-- different aspects of the street network (sidewalk vs main roads), we are going to rely on the geomtry properties and
-- spatial relationships to find potential matches. So, we want:
-- 1. buffering
-- 2. intersection with buffer of the road segment
-- 3. parallel

SELECT sidewalk.*
FROM osm_sidewalk_udistrict1 sidewalk

SELECT *
FROM arnold.segment_test_line

-- This code will join the segments with the roads that are:
-- 1. the road buffer and the sidewalk buffer overlap
-- 2. the road and the sidewalk are parallel to each other (between 0-30 or 165/195 or 330-360 degree)
-- 3. in case where the sidewalk.geom looking at more than 2 road.geom at the same time, we need to choose the one that have the closest distance
--    from the midpoint of the sidewalk to the midpoint of the road
-- 4. Ignore those roads that are smaller than 10 meters
CREATE TABLE conflation.long_parallel AS
WITH ranked_roads AS (
  SELECT
    sidewalk.osm_id AS sidewalk_id,
    road.objectid AS road_id,
    road.routeid AS road_routeid,
  	sidewalk.geom AS sidewalk_geom,
    road.geom AS road_geom,
    ABS(DEGREES(ST_Angle(road.geom, sidewalk.geom))) AS angle_degrees,
    ST_Distance(ST_LineInterpolatePoint(road.geom, 0.5), ST_LineInterpolatePoint(sidewalk.geom, 0.5)) AS midpoints_distance,
    ST_length(sidewalk.geom) AS sidewalk_length,
    -- rank this based on the distance of the midpoint of the sidewalk to the midpoint of the road
    ROW_NUMBER() OVER (PARTITION BY sidewalk.geom ORDER BY ST_Distance(ST_LineInterpolatePoint(road.geom, 0.5), ST_LineInterpolatePoint(sidewalk.geom, 0.5)) ) AS RANK
  FROM
    osm_sidewalk_udistrict1 sidewalk
  JOIN
    arnold.segment_test_line road
  ON
    ST_Intersects(ST_Buffer(sidewalk.geom, 2), ST_Buffer(road.geom, 15))  -- need TO MODIFY so so we have better number, what IF there 
  WHERE (
    	   ABS(DEGREES(ST_Angle(road.geom, sidewalk.geom))) BETWEEN 0 AND 10 -- 0 
    	OR ABS(DEGREES(ST_Angle(road.geom, sidewalk.geom))) BETWEEN 170 AND 190 -- 180
    	OR ABS(DEGREES(ST_Angle(road.geom, sidewalk.geom))) BETWEEN 350 AND 360) -- 360
   AND ( ST_length(sidewalk.geom) > 10 ) -- IGNORE sidewalk that ARE shorter than 10 meters
)
SELECT
  sidewalk_id,
  road_id,
  road_routeid,
  angle_degrees,
  midpoints_distance,
  sidewalk_length,
  sidewalk_geom,
  road_geom
FROM
  ranked_roads
WHERE
  rank = 1;

-- next step: how to work around with those that serve as a "connecting" between this centerline of the sidewalk to another centerline of the sidewalk?
