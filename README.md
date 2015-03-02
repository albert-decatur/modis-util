# modis-util

### what it does

* downloads MODIS products according to user shapefile boundary
* for user defined ISO date range
* clips to user shapefile
* mosaics
* reprojects
* filters by user defined quality control regular expression

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

  * 100 minutes for download
  * 30 minutes for processing
