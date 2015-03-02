MODIS Grid based on Sinusoidal Projection
(with MODIS Sphere +a=6371007.181 +b=6371007.181)

Software: GRASS GIS 6.4

World map source: "admin98.zip" from http://mappinghacks.com/data/
- Imported into GRASS GIS (v.in.ogr)
- Reprojected to Sinusoidal in GRASS (v.proj)

World Boundary:
- Generated in LatLong/WGS84 in GRASS (v.in.region, v.split)
- Reprojected to Sinusoidal in GRASS (v.proj)

MODIS Grid
- Generated in Sinusoidal in GRASS (v.mkgrid)

Export to SHAPE: GRASS (v.out.ogr)

Data License: CC-BY-SA if not stated otherwise.

Markus Neteler

Foundation Edmund Mach (FEM) - Research and Innovation Centre
Environment and Natural Resources Area
GIS and Remote Sensing Unit, Trento, Italy
Web:  http://gis.fem-environment.eu/
Email: neteler AT cealp.it
Book: http://www.grassbook.org/

