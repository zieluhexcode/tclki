#########################################################################################
# Name          m00nie::youtube
# Description   Uses youtube v3 API to search and return videos
#
# Version  2.6 - Add likes to auto spam (Thanks to ComputerTech for the suggestion)
#                also a small update to time formating
#          2.5 - Correctly returns results for channels rather than videos for !yt
#          2.4 - Fixing bug that meant date was again reported wrongly. Thanks
#               to caesar for suggesting the fix
#          2.3 - Fix for new date/time results from the API
#          2.2 - Reodering throttling to make it work better....
#          2.1 - Adds throttling to spammed links themselves (link_throt)
#               Also includes a fix on some character output with !yt searching
#               Thanks to <AlbozZ> for this spot and fix!
#          2.0 - Adds seperate flag for search and autoinfo (suggestion from m4s)
#                This is a change from previous versions
#               .chanset #chan +youtube = Enabled auto info grabbing on a URL spam
#               .chanset #chan +youtubesearch = Enabled access to search via !yt
#          1.9 - Adding throttling controls (per user and per chan)
#          1.8 - Chanset +youtube now controls search access!
#          1.7 - Modify SSL params (fixes issues on some systems)
#          1.6 - Small correction to "stream" categorisation.....
#          1.5 - Added UTF-8 support thanks to CatboxParadox (Requires eggdrop
#               to be compiled with UTF-8 support)
#          1.4 - Correct time format and live streams gaming etc
#          1.3 - Updated output to be RFC compliant for some IRCDs
#          1.2 - Added auto info grabber for spammed links
#          1.1 - Fixing regex!
#          1.0 - Initial release
# Website       https://www.m00nie.com/youtube-eggdrop-script-using-api-v3/
# Notes         Grab your own key @ https://developers.google.com/youtube/v3/
#########################################################################################
namespace eval m00nie {
   namespace eval youtube {
    # ----- CHANGE these variables -----
    # This key is your own and shoudl remain a secret (e.g please dont email it to me! Obtain it on the link above in the notes)
    variable key "AIzaSyAGn9u0b9SgYNGKAmNbU_u2KEhi38mOD68"
    # The two variables below control throttling in seconds. First is per user, second is per channel third is per link
    variable user_throt 30
    variable chan_throt 10
    variable link_throt 300


    # ---- Dont change things below this line -----
    package require http
    package require json
    # We need to verify the revision of TLS since prior to this version is missing auto host for SNI
    if { [catch {package require tls 1.7.11}] } {
    	# We dont have an autoconfigure option for SNI
    	putlog "m00nie::youtube *** WARNING *** OLD Version of TLS package installed please update to 1.7.11+ ... "
	http::register https 443 [list ::tls::socket -servername www.googleapis.com]
    } else {
    	package require tls 1.7.11
	http::register https 443 [list ::tls::socket -autoservername true]
    }
    bind pub - !yt m00nie::youtube::search
    bind pubm - * m00nie::youtube::autoinfo
    variable version "2.6"
    setudef flag youtube
    setudef flag youtubesearch
    variable regex {(?:http(?:s|).{3}|)(?:www.|)(?:youtube.com\/watch\?.*v=|youtu.be\/)([\w-]{11})}
    ::http::config -useragent "Mozilla/5.0 (X11; Fedora; Linux x86_64; rv:86.0) Gecko/20100101 Firefox/86.0"
    variable throttled

#### Script Starts here #####

proc autoinfo {nick uhost hand chan text} {
    if {[channel get $chan youtube] && [regexp -nocase -- $m00nie::youtube::regex $text url id]} {
        if {[throttlecheck $nick $chan $id]} { return 0 }
	putlog "m00nie::youtube::autoinfo is running"
        putlog "m00nie::youtube::autoinfo url is: $url and id is: $id"
        set url "https://www.googleapis.com/youtube/v3/videos?id=$id&key=$m00nie::youtube::key&part=snippet,statistics,contentDetails&fields=items(snippet(title,channelTitle,publishedAt),statistics(viewCount,likeCount,dislikeCount),contentDetails(duration))"
        set ids [getinfo $url]
        set title [encoding convertfrom [lindex $ids 0 1 3]]

        set pubiso [lindex $ids 0 1 1]
        set pubiso [string map {"T" " " ".000Z" "" "Z" ""} $pubiso]
        set pubtime [clock format [clock scan $pubiso] -format {%a %b %d %H:%M:%S %Y}]

        set user [encoding convertfrom [lindex $ids 0 1 5]]
        # Yes all quite horrible...
        set isotime [lindex $ids 0 3 1]
        regsub -all {PT|S} $isotime "" isotime
        regsub -all {H|M} $isotime ":" isotime
        if { [string index $isotime end-1] == ":" } {
            set sec [string index $isotime end]
                        set trim [string range $isotime 0 end-1]
                        set isotime ${trim}0$sec
        } elseif { [string index $isotime 0] == "0" } {
            set isotime "stream"
        } elseif { [string index $isotime end-2] != ":" } {
            set isotime "${isotime}s"
        }
        set views [lindex $ids 0 5 1]
	set like [lindex $ids 0 5 3]
	# At the moment not used (it looked a little messy)
	set dis [lindex $ids 0 5 5]
        puthelp "PRIVMSG $chan :\002\00301,00You\00300,04Tube\003\002 \002$title\002 by $user (duration: $isotime) on $pubtime, $views views \[Likes: $like\]"
    }
}

proc throttlecheck {nick chan link} {
	if {[info exists m00nie::youtube::throttled($link)]} {
		putlog "m00nie::youtube::throttlecheck search term or video id: $link, is throttled at the moment"
		return 1
	} elseif {[info exists m00nie::youtube::throttled($chan)]} {
		putlog "m00nie::youtube::throttlecheck Channel $chan is throttled at the moment"
		return 1
	} elseif {[info exists m00nie::youtube::throttled($nick)]} {
		putlog "m00nie::youtube::throttlecheck User $nick is throttled at the moment"
                return 1
	} else {
		set m00nie::youtube::throttled($nick) [utimer $m00nie::youtube::user_throt [list unset m00nie::youtube::throttled($nick)]]
		set m00nie::youtube::throttled($chan) [utimer $m00nie::youtube::chan_throt [list unset m00nie::youtube::throttled($chan)]]
		set m00nie::youtube::throttled($link) [utimer $m00nie::youtube::link_throt [list unset m00nie::youtube::throttled($link)]]
		return 0
	}
}

proc getinfo { url } {
    for { set i 1 } { $i <= 5 } { incr i } {
            set rawpage [::http::data [::http::geturl "$url" -timeout 5000]]
            if {[string length rawpage] > 0} { break }
        }
        putlog "m00nie::youtube::getinfo Rawpage length is: [string length $rawpage]"
        if {[string length $rawpage] == 0} { error "youtube returned ZERO no data :( or we couldnt connect properly" }
        set ids [dict get [json::json2dict $rawpage] items]
    return $ids

}

proc search {nick uhost hand chan text} {
        if {![channel get $chan youtubesearch] } {
                return
        }
    	putlog "m00nie::youtube::search is running"
    	regsub -all {\s+} $text "%20" text
        if {[throttlecheck $nick $chan $text]} { return 0 }
    	set url "https://www.googleapis.com/youtube/v3/search?part=snippet&fields=items(id(videoId),id(channelId),snippet(title))&key=$m00nie::youtube::key&q=$text"
    	set ids [getinfo $url]
    	set output "\002\00301,00You\00300,04Tube\003\002 "
    	for {set i 0} {$i < 5} {incr i} {
        	set id [lindex $ids $i 1 1]
        	set type [lindex $ids $i 1 0]
        	# Catch Channels rather than videos (youtu.be doesnt work for channels)
                if {$type eq "channelId"} {
                        set yout "https://www.youtube.com/channel/$id"
                } else {
                        set yout "https://youtu.be/$id"
                }
        	set desc [encoding convertto utf-8 [lindex $ids $i 3 1]]
		set desc [string map -nocase [list "&amp;" "&" "&#39;" "'" "&quot;" "\""] $desc ]
        	append output "\002" $desc "\002 - " $yout " | "
    	}
    	set output [string range $output 0 end-2]
    	puthelp "PRIVMSG $chan :$output"
}
}
}
putlog "m00nie::youtube $m00nie::youtube::version loaded"
