# modis-util

### What it does

* downloads MODIS products according to user shapefile boundary
* for user defined ISO date range
* clips to user shapefile
* mosaics
* reprojects
* filters by user defined quality control regular expression
* parallel by default, including across hosts

### Example modis-util output

  * in directories that are organized by MODIS acquisition date
  * subsets of choice, in the output/ example case they are NDVI and quality layers from MOD13A2 1km 16 day composites
  * clipped to user shapefile boundary - in the output/ example case New Orleans city boundary
  * mosaicked 
  * QC filtered according to user regular expression
    * in the output/ example case "(0000|0001|0010|0100|1000)(01|00)$"
  * reprojected, in the output/ example case to WGS84 
  * only for the date range provided by the user, in the output/ example case the entire MODIS archive

Example execution time on a 1 CPU 2GB RAM machine (seriously minimal hardware!):

* 1 minute 30 seconds to process two dates for New Orleans NDVI

Example was executed this way:

```bash
./modis-util.sh\
-p MOD13A2.005\
# get these bands from HDF inputs
-x "ndvi quality"\
# use tiles from this date range
-d "2014-09-29 2014-10-30"\
# reproject to WGS84
-s 4326\
# put outputs - organized by date - into output/ directory
-o output/ \
# use this regular expression for enforcing rules in quality band
-q "(0000|0001|0010|0100|1000)(01|00)$"\
# use quality band to enforce rules on ndvi band
-l "quality ndvi"\
# use this shapefile as the MODIS tile template
-t input/modis_sinusoidal/modis_sinusoidal_grid_world.shp\
# clip to New Orleans boundary before mosaicking
-b input/boundary/NOLA/NOLA_Boundary.shp
```


### Prerequisites

* GDAL/OGR
* SpatiaLite
* GNU parallel
* lftp
* moreutils

List of land tiles comes from [here](https://nsidc.org/data/docs/daac/mod10_modis_snow/sinusoidal_tile_coordinates.html).
