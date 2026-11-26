The compressed UDF 1.02 DVD contains original, synthetic MPEG-2 pictures and
stereo AC-3 audio. Title 1 is blue with a 660 Hz tone for 7.007 seconds. Title 2
plays green (440 Hz) followed by blue, totalling 14.014 seconds. The blue cell is
shared between titles. The second title therefore exercises playback in a different
order from the physical VOB data. To generate an equivalent fixture on macOS:

```sh
for pair in green:440 blue:660; do
  color=${pair%:*}
  frequency=${pair#*:}
  ffmpeg -f lavfi -i "color=c=$color:s=352x240:r=30000/1001" \
    -f lavfi -i "sine=frequency=$frequency:sample_rate=48000" -t 7 \
    -target ntsc-dvd -s 352x240 -b:v 700k -c:a ac3 -ac 2 -b:a 192k "$color.mpg"
done
cat > dvd.xml <<'XML'
<dvdauthor dest="disc" format="ntsc">
  <vmgm/>
  <titleset><titles>
    <pgc><vob file="blue.mpg"/></pgc>
    <pgc><vob file="green.mpg"/><vob file="blue.mpg"/></pgc>
  </titles></titleset>
</dvdauthor>
XML
dvdauthor -x dvd.xml
hdiutil makehybrid -udf -udf-version 1.02 -o movie.iso disc
gzip -nc movie.iso > dvd_titles.iso.gz.bin
```
