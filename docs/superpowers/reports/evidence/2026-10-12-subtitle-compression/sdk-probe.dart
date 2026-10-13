import 'dart:io';
void main(){final b=zlib.encode([65,66,67]);for(final entry in {'valid':b,'truncated':b.sublist(0,b.length-1),'trailing':[...b,1,2,3],'concatenated':[...b,...b],'gzip':gzip.encode([65,66,67])}.entries){try{print('${entry.key} ${ZLibDecoder().convert(entry.value)}');}catch(e){print('${entry.key} ${e.runtimeType}');}}}
