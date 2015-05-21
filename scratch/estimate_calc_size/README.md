# estimate size calc for space beats time, HURDAT2

* starts in 1999 goes to end of HURDAT2
* covers list of MODIS tiles that intersect land (according to ne 10m land mask) AND have at least one HURDAT2 SSHWS > 1 point w/i 150 miles (average hurricane swath assumed to be 300 miles) THAT intersected land
* for each storm
  * find count dates for each tile
  * sum pixels to process - this is all dates for all tiles involved
