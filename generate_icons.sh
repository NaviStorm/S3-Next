#!/bin/bash

SOURCE="S3-next.ink.png"
DEST="S3 Vue/Assets.xcassets/AppIcon.appiconset"

# Function to resize
resize() {
    local size=$1
    local scale=$2
    local idiom=$3
    local final_size=$(echo "$size * $scale" | bc | cut -d. -f1)
    local filename="icon_${idiom}_${size}x${size}@${scale}x.png"
    
    echo "Generating $filename ($final_size x $final_size)..."
    sips -z $final_size $final_size "$SOURCE" --out "$DEST/$filename" > /dev/null
}

# Mac sizes
resize 16 1 mac
resize 16 2 mac
resize 32 1 mac
resize 32 2 mac
resize 128 1 mac
resize 128 2 mac
resize 256 1 mac
resize 256 2 mac
resize 512 1 mac
resize 512 2 mac

# iOS sizes
resize 20 2 iphone
resize 20 3 iphone
resize 29 2 iphone
resize 29 3 iphone
resize 40 2 iphone
resize 40 3 iphone
resize 60 2 iphone
resize 60 3 iphone

resize 20 2 ipad
resize 29 2 ipad
resize 40 2 ipad
resize 76 2 ipad
resize 83.5 2 ipad

# App Store
resize 1024 1 ios-marketing

echo "Done!"
