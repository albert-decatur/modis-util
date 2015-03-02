# modis-util

### what it does

* downloads MODIS products according to user shapefile boundary
* for user defined ISO date range
* clips to user shapefile
* mosaics
* reprojects
* filters by user defined quality control regular expression

### Example modis-util output

* outputs are . . .

  * in directories that are organized by MODIS acquisition date
  * subsets of choice, in this case the NDVI and quality layers from MOD13A2 1km 16 day composites
  * clipped to user shapefile boundary - in this case New Orleans city boundary
  * mosaicked 
  * QC filtered according to user regular expression
    * in this case "(0000|0001|0010|0100|1000)(01|00)$"
  * reprojected to WGS84
  * only for the date range provided by the user, in this case the entire MODIS archive

Execution time on a 1 CPU 2GB RAM machine:

  * 100 minutes for download
  * 30 minutes for processing

File size:

  * input: >8GB
  * output: <1MB
