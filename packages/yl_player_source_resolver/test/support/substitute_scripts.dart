// Independently authored test scripts. Only the synthetic API and media URLs
// are bound by the device harness. The caller still passes the historical raw query.
const substituteScripts = <String, String>{
  'JS-01': r'''
function main(query) {
  const reply = JSON.parse(mytv.get(api + "?" + query));
  return JSON.stringify({url: reply.data.video_stream[0].stream_url, error: reply.error});
}
''',
  'JS-02': r'''
function main(query) {
  const id = parseItems(query).id;
  const time = String(Math.floor(Date.now() / 1000));
  const reply = mytv.request(api + "?id=" + id, "GET", ["x-emas-gw-t: " + time]);
  if (reply.code !== 200) throw Error("fixture response");
  const inner = JSON.parse(CryptoJS.enc.Base64.parse(JSON.parse(reply.body).response)
    .toString(CryptoJS.enc.Utf8)).data;
  const key = CryptoJS.enc.Utf8.parse(inner.dk.slice(0, 8) + time.slice(-8));
  const iv = CryptoJS.enc.Utf8.parse(inner.dk.slice(-8) + time.slice(0, 8));
  const ciphertext = inner.live_room.liveCameraList[0].pullUrlList[0].authResultUrl[0].authUrl;
  const url = CryptoJS.AES.decrypt(ciphertext, key, {iv: iv, mode: CryptoJS.mode.CBC,
    padding: CryptoJS.pad.Pkcs7}).toString(CryptoJS.enc.Utf8);
  return JSON.stringify({url});
}
''',
  'JS-03': r'''
function main(query) {
  const reply = mytv.get(api + "?" + query, ["Host: " + authority]);
  return JSON.stringify({url: JSON.parse(reply).data[0].httpUrl});
}
''',
  'JS-04': r'''
function main(query) {
  return JSON.stringify({url: JSON.parse(mytv.fetch(api + "?" + query)).stream_url});
}
''',
  'JS-05': r'''
function main(query) {
  const id = parseItems(query).id;
  const reply = JSON.parse(mytv.get(api + "?id=" + id));
  return JSON.stringify({url: reply.resultSet[0].url, headers: {"X-Channel": id}});
}
''',
  'JS-06': r'''
function main(query) {
  const channels = {dfws: 2030};
  const id = query.slice(3);
  const reply = JSON.parse(mytv.post(api + "?" + query, [], "{}"));
  return JSON.stringify({url: reply.dt.find(row => row.id === channels[id]).channelUrl});
}
''',
  'JS-07': r'''
function main(query) {
  const id = parseItems(query).id;
  const reply = JSON.parse(mytv.get(api + "?id=" + id));
  const t = Math.floor(Date.now() / 1000).toString(16);
  const path = "/fixture.m3u8";
  const input = reply.sign.replace("{IP}",reply.ip).replace("{KEY}",reply.key)
    .replace("{PATH}",path).replace("{T}",t);
  const sign = CryptoJS.MD5(input).toString();
  return JSON.stringify({url: media + "?sign=" + sign + "&t=" + t,
    headers: ["Referer: https://fixture.invalid/", "referer: https://fixture.invalid/"]});
}
''',
  'JS-08': r'''
function main(query) {
  const channels = {xjws: 1};
  const id = query.slice(3);
  const reply = JSON.parse(mytv.fetch(api + "?" + query));
  return JSON.stringify({url: reply.data.find(row => row.Id === channels[id]).PlayStreamUrl});
}
''',
  'JS-09': r'''
function main(query) {
  const time = String(Math.floor(Date.now() / 1000));
  const nonce = CryptoJS.MD5(query).toString();
  const token = time + "-" + nonce + "-0";
  const digest = CryptoJS.MD5("/fixture.m3u8|" + token + "|fixture").toString();
  return JSON.stringify({url: media + "?auth_key=" + token + "-" + digest});
}
''',
};
