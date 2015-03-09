#!/bin/bash

# TODO - features to add
# 1. let user filter by XML contents before downloading, eg cloud cover and missing %
# 2. capture more nodata outputs - eg GDAL's nodata vs a layer's FILLNUM
# 3. option to preview browse JPG before download
# 4. if the output of masking according to user QC flag regex is all null then delete the acquisition date directory
# 5. allow to filter by tiles with land or water or both
# 6. have MODIS tiles from Neteler come prepackaged as SQLite db (with attribute for whether they are land or water)

# NB
# GDAL 1.10 might have to be used so that gdal_merge.py has the -a_nodata flag available

usage()
{
cat << EOF

* use shapefile and an ISO date range to download, clip, and mosaic MODIS (specifically MOLT for now) products
* keeps only the HDF subsets that match your list (eg "ndvi quality")
* keeps only pixels that match your QC regular expression
* can reproject outputs
* originally designed for MOD13A2 - beware if applying to other products!

example use: 
$0 -p MOD13A2.005 -x "ndvi quality" -d "2014-09-29 2014-10-30" -s 4326 -o ndvi/ -q "(0000|0001|0010|0100|1000)(01|00)$" -l "quality ndvi" -t input/modis_sinusoidal/modis_sinusoidal_grid_world.shp -b input/boundary/NOLA/NOLA_Boundary.shp
$0 -p MOD14A1.005 -x "firemask qa" -d "2001-09-13 2001-09-16" -s 4326 -o fire/ -t input/modis_sinusoidal/modis_sinusoidal_grid_world.shp -b input/boundary/NOLA/NOLA_Boundary.shp

OPTIONS:
   -h      Show this message
   -b      boundary shapefile this must be in the MODIS sinusoidal projection
	   TODO: not providing this option still allows for a tile list to be chosen one per line in a file - ideal when whole tiles are desired
   -t      tile template shapefile can be found at http://gis.cri.fmach.it/modis-sinusoidal-gis-files/
   -d      double quoted date range, written as "YYYY-MM-DD YYYY-MM-DD".
	   Note that dates refer to the acquisiton date of the image.
	   TODO: not providing this option means the full date range will be taken
   -p      MODIS product name with version number, eg MOD13A2.005
   -x      subdataset extraction terms - these are double quoted words that will match the subdatasets of interest, like "ndvi quality"
           Note: these will be searched for in gdalinfo output on the downloaded HDFs.  they will also be used in output file names
           only one word per subset. (regex would be better)
   -s	   output spatial reference system as EPSG code. 
   -q      QC flag regular expression. Should be quoted.
	   Note: QC flags read from right to left.  also, this has only been tested on MOD13A2
   -l      layers to use for QC filtering - first is the QC layer, second is the layer to filter
	   Note: these must be the same terms used in the -x flag
           TODO: ability to filter more than one layer
   -o      output directory for mosaicked and clipped tifs - clips to boundary vector
	   Note: the outpur directory will be made if necessary.  it ought to be empty
   -k      use this flag to keep input HDF files
EOF
}

while getopts "hb:t:p:d:s:o:x:q:l:k" OPTION
do
     case $OPTION in
         h)
             usage
             exit 1
             ;;
         b)
             boundary=$OPTARG
             ;;
         t)
             tiletemplate=$OPTARG
             ;;
         p)
             product=$OPTARG
             ;;
         x)
             subdataset_terms=$OPTARG
             ;;
         d)
             daterange=($OPTARG)
             ;;
         s)
             srs=$OPTARG
             ;;
         l)
             qc_layers=$OPTARG
             ;;
         q)
             qc_regex=$OPTARG
	     # as a file for GNU parallel's sake
	     tmpqcregex=$(mktemp)
	     echo "$qc_regex" > $tmpqcregex
             ;;
         o)
             outdir=$OPTARG
	     mkdir $outdir 2>/dev/null
             ;;
         k)
             keep=1
             ;;
         ?)
             usage
             exit
             ;;
     esac
done

function numericdates {
	# checks if YYYY-MM-DD USGS directories are within user specified date range
	# used by download function to check relevant directories faster
	# these are referred to as numeric because they are ISO dates without the hypens
	numericstart=$(	
		echo ${daterange[0]} |\
		sed 's:-::g'
	)
	numericend=$(
		echo ${daterange[1]} |\
		sed 's:-::g'
	)
}

function julianstartend {
	# julian dates are used to ensure correct files are downloaded
	# however, the USGS directory structure with ISO dates is relied on for speed
	juliandays=$(
		for date in $( echo ${daterange[*]} )
		do
			year=$(echo $date | grep -oE "^[0-9]{4}")
			julianday=$( date -d "$date" +%j )
			echo ${year}${julianday}
		done |\
		sort -n 
	)
	julianstartdate=$(
		echo "$juliandays" |\
		sed -n '1p'
	)
	julianenddate=$(
		echo "$juliandays" |\
		sed -n '2p'
	)
}

function find_tiles {
	# used by download function to determine which tiles are of interest
	# load MODIS template and boundary shp into spatialite db
	tmpsqlite=$(mktemp)
	for shp in $boundary $tiletemplate
	do
		spatialite_tool -i -shp $( echo $shp | sed 's:[.]shp$::g' ) -t $( basename $shp .shp ) -d $tmpsqlite -g geom -c CP1252
	done
	# find the horizontal and vertical names of the MODIS tiles that intersect the boundary shp
	tiles=$(
		echo -e ".mode tabs\nselect t.h,t.v from $( basename $boundary .shp ) as b, $( basename $tiletemplate .shp ) as t where intersects(t.geom,b.geom);" |\
		spatialite $tmpsqlite |\
		# make sure that numbers are printed with leading zeroes as necessary
		awk -F '\t' '{ OFS="\t"; h=sprintf("%02i", $1); v=sprintf("%02i", $2); print "h"h,"v"v }' |\
		# get just unique list of tiles - multiple features may overlap same tiles
		sort |\
		uniq |\
		# format the text for the MODIS archive, eg h10v06
		sed 's:\t::g'
	)
}

function download_list {
	# get the start and end julian dates from the user
	julianstartend
	# get MODIS tiles that are intersected by the boundary shp
	find_tiles
	# format tile lists for regex by grep
	tiles=$(
		echo "$tiles" |\
		# isolate tile position in parens
		sed 's:^:(:g;s:$:):g' |\
		# tack on regex requirement that the file be hdf or xml
		sed 's:$:.*[.](hdf|xml)$:g'
	)
	# the base URL - this may change!
	# note that $product is the name of the user selected product, eg MOD13A2.005
	baseuri="http://e4ftl01.cr.usgs.gov/MODIS_Composites/MOLT/${product}/"
	# on this first pass through the USGS archive, establish which directories, according to ISO date, are worth looking at given the user provided date range
	# first make YYYYMMDD versions of our input user date range for awk
	numericdates
	isodirs=$(
		lftp -e 'find -d2; exit' $baseuri |\
		sed "s:^[.]\|/::g;s:[.]::g" |\
		awk "{if(\$1 >= $numericstart && \$1 <= $numericend )print \$0}" |\
		# return dates from numeric comparison style (YYYYMMDD) to USGS directory style (YYYY.MM.DD)
		sed 's:^\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\):\1.\2.\3:g' |\
		# ensure these appear on a single line for the convenience of lftp find command
		tr '\n' ' '
	)
	# on this second pass, target the ISO date directories of interest, find the relevant images by tile and official julian date
	# this is very efficient for small date ranges but might be inefficient for large ones
	lftp -e "find $isodirs; exit" $baseuri |\
	# ensure that only images from the relevant tiles are downloaded
	grep -Ef <( echo "$tiles" ) |\
	# ensure that only images from the relevant dates are downloaded
	# note that this is very sensitive to whether there is a leading period - this changes the column position of julian dates in file names
	# note that the "A" from the aquisition julian date is first being removed then added again
	awk -F'.' "{ OFS=\".\"; sub(/^A/,\"\", \$4); if( \$4 >= $julianstartdate && \$4 <= $julianenddate ) { sub(/^/,\"A\",\$4); print \$0 } }" |\
	# add the baseuri to the front of th file names
	# note that for the benefit of sed the baseuri has all forward slashes and semicolons escaped
	sed "s:^:$( echo ${baseuri} | sed 's:\(/\|\:\):\\\1:g' ):g"
}

# write function definitions used by GNU parallel to file using HERE doc
# these can be shared with remote hosts later with GNU parallel --bf
# note use of escaping HERE doc limit string to output literal text
# note the function download_list and the functions it depends on are defined before GNU parallel as they generate the input for parallel
cat > /tmp/functions << \EOF


function download {
	# download the images of interest
	# what if the list is too long for xargs? GNU parallel?
	wget -q -P $2 -c $1
}
export -f download

function subdataset { 
	# extracts subdatasets from HDF according to HDF name and term relevant to subdataset, eg quality or ndvi
	# terms are not case sensitive - this makes file naming from terms nice but is very sensitive to GDAL utility outputs
	# these are the files that get clipped, whose clipped parts are mosaicked according to date, and whose mosaics are QC masked
	inhdf=$1
	term=$2
	suboutdir=$3
	subdataset_name=$( 
		gdalinfo $inhdf |\
		grep -oiE "SUBDATASET_[0-9]+_NAME=.*[.]hdf.*$term" |\
		grep -oE "[^=]*$" 
	)
	subfilename=$( 
		basename $inhdf .hdf |\
		sed "s:^:${term}_:g;s:$:.tif:g" 
	)
	gdal_translate -of GTiff -co COMPRESS=DEFLATE "$subdataset_name" $suboutdir/$subfilename
}
# export function so GNU parallel can see it
export -f subdataset

function find_nodata { 
	# for user specified subset terms, like ndvi and quality, get subsets, clip each subset by each tile given the user specified boundary, and mosaic
	# clipping each subset by each tile before mosaicking (instead of mosaicking all and clipping by boundary after) takes more steps but is more memory efficient (unless whole tiles are desired - ought to create an alternative using a text file of tile lists)
	# respects input nodata of the subset
	acquisition_date_dir=$1
	term=$2
	acquisition_date=$( echo $acquisition_date_dir | grep -oE "[^/]*$" )
	# subdataset_terms must not be in double quotes here - each term is processed
		# establish nodata value for this subset
		# will be used by subsequent GDAL utils
		example_file=$( 
			find $acquisition_date_dir -type f -iregex ".*/${term}.*[.]tif$" |\
			sed -n "1p" 
		) 
		# TODO: this works for GDAL responses including "NoData Value" and "NUMFILL" - but what about others?
		nodata=$(
			# it is assumed that a subset has a single nodata value
			gdalinfo $example_file |\
			grep -iE "NoData Value=|NUMFILL=" |\
			grep -oE "[0-9.-]+" |\
			sed -n "1p"
		)
		# assume that if no nodata is found then there is no nodata
		# this may often be false!
		if [[ -n $nodata ]]; then
			# if a nodata value is found then GDAL utils will use it
			srcdst_nodata="-srcnodata $nodata -dstnodata $nodata"
			merge_nodata="-n $nodata -a_nodata $nodata"
		else
			# if there is no nodata found then GDAL utils will ignore it
			srcdst_nodata=""
			merge_nodata=""
		fi
}
export -f find_nodata

function clip {
	acquisition_date_dir=$1
	to_crop=$2
	# for each extracted subset of the date and term, crop to user boundary
	# cutline on user boundary
	gdalwarp $srcdst_nodata -r near -cutline $boundary -crop_to_cutline -of GTiff -co COMPRESS=DEFLATE $to_crop $(echo $to_crop | sed "s:\(${term}_\):crop_\1:g")
}
export -f clip

function mosaic {
	acquisition_date_dir=$1
	term=$2
	# mosaic the output crops
	gdal_merge.py $merge_nodata -of GTiff -co COMPRESS=DEFLATE -o $acquisition_date_dir/mosaic_crop_${term}_$product.$acquisition_date.tif $acquisition_date_dir/crop_${term}*.tif
}
export -f mosaic

function reproject {
	acquisition_date_dir=$1
	term=$2
	# reproject if user raised flag
	# as ridiculous as this seems, it is needed in case the -s flag is not raised. that, or flip the if condition
	srs=$srs
	if [[ -n $srs ]]; then
		gdalwarp -t_srs EPSG:$srs $srcdst_nodata -r near $acquisition_date_dir/mosaic_crop_${term}_$product.$acquisition_date.tif $acquisition_date_dir/mosaic_crop_${term}_$product.$acquisition_date.tif.reproject
		# overwrite - keep that old filename
		mv $acquisition_date_dir/mosaic_crop_${term}_$product.$acquisition_date.tif.reproject $acquisition_date_dir/mosaic_crop_${term}_$product.$acquisition_date.tif
	fi
}
export -f reproject

function filter_QC {
	# 1. use GDAL to make ASCII grid to find unique non-null values in the quality layer
	# 2. convert these to binary
	# 3. check which are acceptable according to user QC regex
	# 4. mask these pixels out in second layer of interest using gdal_calc 
	# it is possible that just having a completed look up table is a better approach but this lets the user provide an arbitrary regex for any MODIS product

	qc_layer=$1
	data_layer=$2
	qc_regex=$( cat $3 )
	acquisition_date_dir=$4

	# get the clipped, mosaicked subsets as ASCII grid
	# note that it might be inefficient to check QC flags by date when they could all be checked at once
	# however, on larger datasets it might also break sort, uniq, etc to ask them to process all the ASCII grids at once
	tmpgrid=$(mktemp)
	gdal_translate -of AAIGrid $qc_layer $tmpgrid
	# find quality nodata value
	nodata=$(
		grep NODATA_value $tmpgrid |\
		awk "{ print \$2 }"
	)
	# create a tmp file to hold blacklisted pixel values
	tmpblacklist=$(mktemp)
	cat $tmpgrid |\
	# ignore header
	sed "1,6d" |\
	tr " " "\n" |\
	grep -vE "^$" |\
	# get unique pixel values
	sort |\
	uniq |\
	# ignore nodata
	grep -vE "$nodata" |\
	# for each unique non-null pixel value, get the QC 16bits
	while read bitpacked
	do 
		# pass the int to bc to get binary
		echo "obase=2; $bitpacked" |\
		bc |\
		# now we need to pad with leading zeroes
		# I have no idea why but the following does work for 16bit
		# printf was not a solution!
		# credit goes to Jonathan Leffler
		# http://stackoverflow.com/questions/12633522/prevent-bc-from-auto-truncating-leading-zeros-when-converting-from-hex-to-binary
		# pad binary with leading zeroes as needed to show 16 bits
		awk "{ len = (8 - length % 8) % 8; printf \"%.*s%s\n\", len, \"00000000\", \$0}" |\
		# show the bitpacked int as well for lookup later
		sed "s:^:$bitpacked\t:g"
	done |\
	# use the user provided regex to find acceptable bitpacked int values in the QC maps
	# note that QC field reads from right to left
	# store them in a tmp blacklist
	awk "{if(\$2 !~ /$qc_regex/)print \$1}" |\
	tr "\n" "|" |\
	sed "s:|$::g;s:|:\\\|:g" \
	> $tmpblacklist
	# convert this blacklist into nodata value in the ASCII grid
	# TODO: temporarily ignore and then reattach header in case bad quality bitpacked ints appear in ASCII header
	# just in case all pixels are acceptable, do not try to change anything!
	if [[ $( cat $tmpblacklist | grep -vE "^$" | wc -l ) != 0 ]]; then
		sed -i "s:\b\($( cat $tmpblacklist )\)\b:$nodata:g" $tmpgrid
	fi
	# for pixels where the masked grid is null, make your other layer null
	# use of ls to pick up name of layer to mask is sloppy
	gdal_calc.py -A $tmpgrid -B $data_layer --calc="B+1*(A==$nodata)" --outfile=$( dirname $qc_layer )/masked_$( basename $data_layer )
	# replace the old unmasked layer with the masked one
	mv $( dirname $qc_layer )/masked_$( basename $data_layer ) $( dirname $qc_layer )/$( basename $data_layer )
}
export -f filter_QC
EOF

# get the list of HDF to download
download_list=$( download_list )
# save URLs for parallel
tmpdownloadlist=$(mktemp)
echo "$download_list" > $tmpdownloadlist
# get the acquisition dates
echo "$download_list" |\
grep -oE "[.]A[0-9]{7}[.]" |\
sed "s:[.]::g" |\
sort |\
uniq |\
# for each acqusition date, download the HDF and XML
# subset, clip
# check to see if all HDF for a date have been downloaded,
# if so mosaic, reproject, and QC filter
# TODO: conditional on list of hosts
parallel --gnu --bf $tmpdownloadlist --bf /tmp/functions --wd ... -S :,adecatur@grover.itpir.wm.edu '
	# pick up function definitions
	# we source this because of potential remote hosts
	# GNU parallel --env did not work
	source /tmp/functions
	# must do this for GNU parallel to recognize the variable inside the function
	# note: this may only be necessary for vars used in functions
	outdir='$outdir'
	subdataset_terms="'$subdataset_terms'"
	product="'$product'"
	boundary="'$boundary'"
	srs="'$srs'"
	qc_layers="'$qc_layers'"
	tmpqcregex='$tmpqcregex'
	tmpdownloadlist='$tmpdownloadlist'
	# determine how many HDF files (really tiles) there are for this acquisition date
	# this will be needed for determining whether all HDF have been processed for a date and are ready to be mosaiced, reprojected, and QC filtered
	tile_count=$(
		cat $tmpdownloadlist |\
		grep -vE "[.]xml$" |\
		grep {} |\
		wc -l
	)
	# create acquisiton date dir
	acquisition_date_dir=$( echo {} | sed "s:^:${outdir}/:g" )
	mkdir $acquisition_date_dir 2>/dev/null
	# download the hdf and xml
	grep {} $tmpdownloadlist |\
	while read to_download
	do
		# subset and clip the file only if it is HDF
		ext=$( echo $to_download | grep -oE "[^.]*$" )
		if [[ $ext == "hdf" ]]; then
			download $to_download $acquisition_date_dir
			hdf=$( basename $to_download )
			for term in $subdataset_terms
			do
				# extract the subsets for that date and term and move them to the date dir
				subdataset $acquisition_date_dir/$hdf $term $acquisition_date_dir
				find_nodata $acquisition_date_dir $term
				# NB: this must not have a trailing forward slash
				clip $acquisition_date_dir $acquisition_date_dir/${term}_$( basename $to_download hdf)*tif
				to_find=$( basename $( echo "$to_download" ) | sed "s:^\($( echo "$product" | grep -oE "^[^.]*" )[.]A[0-9]\+\)[.].*:\1.*[.]tif$:g;s:^:crop_${term}_:g;s:^:.*:g" )
				to_mosaic=$( find $acquisition_date_dir -type f -iregex "$to_find" )
				if [[ $( echo "$to_mosaic" | wc -l ) -eq $tile_count ]]; then
					mosaic $acquisition_date_dir $term
					reproject $acquisition_date_dir $term
						# remove tmp files
						rm $acquisition_date_dir/crop_${term}*
						rm $acquisition_date_dir/${term}_*
						# better file names
						rename "s:/mosaic_crop_:/:g" $acquisition_date_dir/mosaic_crop_${term}_*
				fi
			done
			# QC flag handling
			if [[ $( echo "$to_mosaic" | wc -l ) -eq $tile_count ]]; then
				layers=($qc_layers)
				qc_layer=$( find $acquisition_date_dir -type f -iregex ".*/${layers[0]}_.*[.]tif$" )
				data_layer=$( find $acquisition_date_dir -type f -iregex ".*/${layers[1]}_.*[.]tif$" )
				filter_QC $qc_layer $data_layer $tmpqcregex $acquisition_date_dir
			fi
			# remove HDF if user did not say to keep - this way we can process more inputs than we have harddrive space
			# remember that we are keeping the URLs
			# make sure to have a keep var at all
			keep='$keep'
			if [[ $keep != 1 ]]; then
				rm $acquisition_date_dir/$( basename $to_download )
			fi
		else
			download $to_download $acquisition_date_dir
		fi
	done
	rm -r /tmp/$( echo $acquisition_date_dir | grep -oE "[^/]*$" )/
	mv $acquisition_date_dir/ /tmp/
'
# keep the list of downloaded files
mv $tmpdownloadlist $outdir/urls.txt
# TODO: put acqusition date dirs back together under single out dir, no matter which host they come from
