WITH LineString AS (
    SELECT 'LINESTRING (-13643088.382130755 5705342.331268667, -13643088.279276878 5705342.330547186, -13643021.411308505 5705341.885621492, -13642983.362047205 5705341.631370248, -13642966.730859052 5705341.520135708)'::geometry AS geom
),
GivenPoint AS (
    SELECT 'POINT (-13643088.382130755 5705342.331268667)'::geometry AS geom
)
SELECT 
    ST_LineInterpolatePoint(geom, 
        ST_LineLocatePoint(geom, (SELECT geom FROM GivenPoint)) + 1.0 / ST_NumPoints(geom)
    ) AS next_vertex
FROM LineString;

CREATE OR REPLACE FUNCTION jolie_portland_1.ST_AsMultiPoint(geometry) RETURNS geometry AS
'SELECT ST_Union((d).geom) FROM ST_DumpPoints($1) AS d;'
LANGUAGE sql IMMUTABLE STRICT COST 10;


SELECT DISTINCT poi, ST_ClosestPoint(road, poi)
FROM (SELECT
  (ST_Dump(jolie_portland_1.ST_AsMultiPoint(st_geomfromtext('LINESTRING (-13643088.382130755 5705342.331268667, -13643088.279276878 5705342.330547186, -13643021.411308505 5705341.885621492, -13642983.362047205 5705341.631370248, -13642966.730859052 5705341.520135708)', 3857)))).geom AS road,
  st_geomfromtext('POINT (-13643088.382130755 5705342.331268667)', 3857)::geometry AS poi
) AS f
WHERE NOT ST_Equals(poi, road);-- st_astext(poi) != st_astext(road);


SELECT DISTINCT ON (poi)
    ST_makeline(poi, ST_ClosestPoint(road, poi)),
    ST_ClosestPoint(road, poi) AS closest_point_on_road,
    ST_Distance(poi, road) AS distance
FROM (
    SELECT
        (ST_Dump(jolie_portland_1.ST_AsMultiPoint(ST_GeomFromText('LINESTRING (-13643088.382130755 5705342.331268667, -13643088.279276878 5705342.330547186, -13643021.411308505 5705341.885621492, -13642983.362047205 5705341.631370248, -13642966.730859052 5705341.520135708)', 3857)))).geom AS road,
        ST_GeomFromText('POINT (-13643088.382130755 5705342.331268667)', 3857)::geometry AS poi
) AS f
WHERE NOT ST_Equals(poi, road)
ORDER BY poi, ST_Distance(poi, road);

SELECT ST_makeline(st_startpoint(road), poi), ST_Snap()
FROM (SELECT
  st_geomfromtext('LINESTRING (-13643088.382130755 5705342.331268667, -13643088.279276878 5705342.330547186, -13643021.411308505 5705341.885621492, -13642983.362047205 5705341.631370248, -13642966.730859052 5705341.520135708)', 3857) AS road,
  st_geomfromtext('POINT (-13643088.382130755 5705342.331268667)', 3857)::geometry AS poi
) AS f
WHERE ST_Intersects(ST_Dump(jolie_portland_1.ST_AsMultiPoint(road)), poi) IS FALSE;