# IP-API - 涓€閿洿鎹P鏈嶅姟

涓€涓交閲忕骇鐨?IP 鏇存崲鏈嶅姟锛岄儴缃插湪 VPS 涓婂彲瀹炵幇杩滅▼涓€閿崲IP銆傚熀浜?DHCP 閲嶆柊鐢宠鍜屾満鍣ㄩ噸鍚潵鏇存柊鍏綉 IP锛屾彁渚?Web API 鎺ュ彛銆?
## 馃搵 鍔熻兘鐗规€?
- 鉁?**鏌ョ湅 IP**锛氬疄鏃舵煡璇㈠綋鍓嶆湇鍔″櫒鐨勫叕缃?IP
- 鉁?**鏇存崲 IP**锛氶€氳繃 DHCP 閲嶆柊鐢宠 + 鏈哄櫒閲嶅惎鏉ユ洿鎹?IP
- 鉁?**涓€閿畨瑁?*锛氭敮鎸佸畬鍏ㄨ嚜鍔ㄥ寲閮ㄧ讲锛岃嚜鍔ㄥ鐞嗕緷璧栧拰閰嶇疆
- 鉁?**Token 璁よ瘉**锛氱敓鎴愰殢鏈?Token 淇濇姢 API 鎺ュ彛
- 鉁?**鏅鸿兘闄愭祦**锛氶槻姝㈤绻佽皟鐢紝60 绉掑唴鏈€澶氭崲涓€娆?IP
- 鉁?**鑷姩鍚姩**锛氫互 systemd 鏈嶅姟杩愯锛屾満鍣ㄩ噸鍚悗鑷姩鍚姩
- 鉁?**Web UI**锛氭洿鎹?IP 鏃舵彁渚涘疄鏃惰繘搴︽樉绀洪〉闈?
## 馃殌 蹇€熷紑濮?
### 涓€閿畨瑁?
**瑕佹眰**锛?- 闇€瑕?root 鏉冮檺
- Linux 绯荤粺锛圖ebian/Ubuntu锛?- 缃戠粶杩炴帴姝ｅ父

**瀹夎鍛戒护**锛?
```bash
bash <(curl -fLSs https://raw.githubusercontent.com/vulmallpro-sketch/ip2/main/ip-api-install.sh)
```

**浜や簰寮忓畨瑁呮祦绋?*锛?1. 鑴氭湰浼氭彁绀鸿緭鍏ユ湇鍔″悕绉帮紙榛樿 `ip-api`锛?2. 鑷姩妫€鏌ュ苟瀹夎渚濊禆锛圥ython3銆丳ip銆丆url锛?3. 鐢熸垚 Token 骞堕厤缃?systemd 鏈嶅姟
4. 瀹夎瀹屾垚鍚庢樉绀?API 鍦板潃鍜?Token

**瀹夎杈撳嚭绀轰緥**锛?```
瀹夎 python3...
瀹夎 pip3...
瀹夎鎴愬姛
鏌ヨIP: http://your.server.ip:8080/show/abc123def456
鏇存崲IP: http://your.server.ip:8080/ipch/xyz789abc123
```

### 闈欓粯瀹夎锛堟寚瀹氬弬鏁帮級

濡傛灉闇€瑕佽嚜鍔ㄥ寲鑴氭湰閮ㄧ讲锛屽彲鐢ㄧ幆澧冨彉閲忔寚瀹氬弬鏁帮細

```bash
# 鎸囧畾鏈嶅姟鍚?S=ip-api bash <(curl -fLSs https://raw.githubusercontent.com/vulmallpro-sketch/ip2/main/ip-api-install.sh)

# 鎸囧畾绔彛锛堥€氳繃 PORT 鐜鍙橀噺锛?PORT=9090 bash <(curl -fLSs https://raw.githubusercontent.com/vulmallpro-sketch/ip2/main/ip-api-install.sh)

# 鍚敤璋冭瘯杈撳嚭
DEBUG_INSTALL=1 bash <(curl -fLSs https://raw.githubusercontent.com/vulmallpro-sketch/ip2/main/ip-api-install.sh)
```

## 馃摗 API 浣跨敤

瀹夎瀹屾垚鍚庯紝鑴氭湰浼氳緭鍑轰袱涓?API 鍦板潃鍜屽搴旂殑 Token銆?
### 鏌ヨ IP

**绔偣**锛歚GET /show/{SHOW_TOKEN}`

**鍔熻兘**锛氳幏鍙栧綋鍓嶆湇鍔″櫒鐨勫叕缃?IP

**绀轰緥**锛?```bash
curl http://your.server.ip:8080/show/abc123def456
```

**鍝嶅簲**锛?```json
{
  "ip": "203.0.113.42"
}
```

### 鏇存崲 IP

**绔偣**锛歚GET /ipch/{IPCH_TOKEN}`

**鍔熻兘**锛氳Е鍙?IP 鏇存崲娴佺▼锛圖HCP 閲嶆柊鐢宠 + 鏈哄櫒閲嶅惎锛?
**绀轰緥**锛?```bash
curl http://your.server.ip:8080/ipch/xyz789abc123
```

**娴佺▼**锛?1. 瑙﹀彂璇锋眰鍚庯紝鑴氭湰浼氬湪鍚庡彴鍚姩閲嶅惎娴佺▼
2. 杩斿洖 HTML 椤甸潰锛屾樉绀哄疄鏃舵崲 IP 杩涘害
3. 鑴氭湰鍦ㄥ悗鍙帮細
   - 閲婃斁 DHCP 绉熺害锛坄dhclient -r`锛?   - 绛夊緟 30 绉?   - 閲嶆柊鐢宠 IP锛坄dhclient -v`锛?   - 閲嶅惎鏈哄櫒锛坄reboot`锛?4. 椤甸潰浼氭瘡 5 绉掓煡璇竴娆℃柊 IP锛屾洿鏂拌繘搴?5. 鏂?IP 鑾峰緱鎴栫瓑寰呰秴鏃讹紙200 绉掞級鍚庡仠姝㈣疆璇?
**闄愭祦**锛?- 鍚屼竴鍙版湇鍔″櫒 60 绉掑唴鏃犳硶杩炵画瑙﹀彂鎹?IP
- 瓒呴檺浼氳繑鍥?HTTP 429 鍜岄敊璇俊鎭細`{"error": "too frequent, wait XXs"}`

## 馃摝 瀹夎鏂囦欢璇存槑

瀹夎鍚庣敓鎴愮殑鏂囦欢缁撴瀯锛堥粯璁よ矾寰?`/opt/ip-api`锛夛細

```
/opt/ip-api/
鈹溾攢鈹€ app.py              # Flask 搴旂敤涓绘枃浠?鈹溾攢鈹€ config.json         # 閰嶇疆锛坱oken 鍜岀鍙ｏ級
鈹溾攢鈹€ redial.sh           # DHCP 閲嶆柊鐢宠鍜岄噸鍚剼鏈?鈹斺攢鈹€ ip-api.uninstall.sh # 鍗歌浇鑴氭湰
```

**閰嶇疆鏂囦欢** `config.json`锛?```json
{
  "ipch_token": "鐢熸垚鐨勬洿鎹P Token",
  "show_token": "鐢熸垚鐨勬煡璇P Token",
  "port": 8080
}
```

## 馃敡 绠＄悊鏈嶅姟

鍋囪鏈嶅姟鍚嶄负 `ip-api`锛堥粯璁ゅ€硷級锛?
### 鏌ョ湅鏈嶅姟鐘舵€?```bash
systemctl status ip-api
```

### 鏌ョ湅杩愯鏃ュ織
```bash
journalctl -u ip-api -f
```

### 閲嶅惎鏈嶅姟
```bash
systemctl restart ip-api
```

### 鍋滄鏈嶅姟
```bash
systemctl stop ip-api
```

### 鍗歌浇鏈嶅姟

瀹夎鑴氭湰浼氳嚜鍔ㄧ敓鎴愬嵏杞借剼鏈?`/opt/ip-api.uninstall.sh`锛?
```bash
bash /opt/ip-api.uninstall.sh
```

鎴栨墜鍔ㄥ嵏杞斤細
```bash
systemctl disable --now ip-api
rm -f /etc/systemd/system/ip-api.service
rm -rf /opt/ip-api
```

### 閲嶈鏈嶅姟

濡傛灉闇€瑕侀噸鏂板畨瑁呮浛鎹㈠凡鏈夌殑鏈嶅姟锛岃繍琛屽畨瑁呰剼鏈椂閫夋嫨 `r` 閫夐」锛?
```
璇ユ湇鍔″凡瀛樺湪锛岃鍏堣繍琛屼互涓嬪懡浠ゅ嵏杞斤細
...
鎴栬€呰緭鍏?[r] 褰诲簳閲嶈锛堜笉淇濈暀token锛? r
```

## 鈿欙笍 鐜鍙橀噺鍜岄厤缃?
### 瀹夎鏃跺彲鐢ㄧ殑鐜鍙橀噺

| 鍙橀噺 | 璇存槑 | 绀轰緥 |
|-----|------|------|
| `S` | 鏈嶅姟鍚嶇О | `S=my-api` |
| `PORT` | 鏈嶅姟绔彛 | `PORT=9090` |
| `DEBUG_INSTALL` | 鍚敤璋冭瘯鏃ュ織 | `DEBUG_INSTALL=1` |

### 宸插畨瑁呭悗淇敼閰嶇疆

缂栬緫 `/opt/ip-api/config.json` 鍚庨噸鍚湇鍔★細

```bash
systemctl restart ip-api
```

## 馃洝锔?瀹夊叏寤鸿

1. **Token 淇濇姢**锛歍oken 鏄殢鏈虹敓鎴愮殑锛屼絾寤鸿涓嶈鍦ㄥ叕缃戠洿鎺ユ毚闇茶繖浜涘湴鍧€
   - 浣跨敤 Nginx/Caddy 鍙嶅悜浠ｇ悊娣诲姞璁よ瘉
   - 浣跨敤闃茬伀澧欓檺鍒?IP 璁块棶鑼冨洿

2. **Token 鏇存崲**锛氬鏋?Token 娉勯湶锛岀紪杈?`config.json` 鎵嬪姩淇敼骞堕噸鍚湇鍔?
3. **绔彛閰嶇疆**锛氶粯璁ょ洃鍚?`0.0.0.0`锛堟墍鏈夌綉鍗★級锛屽闇€闄愬埗鍙慨鏀?`app.py`

## 馃摑 鏁呴殰鎺掓煡

### 瀹夎澶辫触锛歱ip3 鎵句笉鍒?
**鐥囩姸**锛?```
/dev/fd/63: line 47: pip3: command not found
```

**瑙ｅ喅**锛?鑴氭湰宸叉敼杩涳紝浼氳嚜鍔ㄥ皾璇?`python3 -m ensurepip` 瀹夎 pip銆傚鏋滀粛鐒跺け璐ワ細

```bash
apt-get update
apt-get install -y python3-pip
```

鐒跺悗閲嶆柊杩愯瀹夎鑴氭湰銆?
### 鏈嶅姟鏃犳硶鍚姩

妫€鏌ユ棩蹇楋細
```bash
journalctl -u ip-api -n 50
```

甯歌鍘熷洜锛?- Port 宸茶鍗犵敤锛氭敼鐢ㄥ叾浠栫鍙ｉ噸瑁?- 鏉冮檺闂锛氱‘淇濅互 root 杩愯
- Python 渚濊禆缂哄け锛氶噸鏂拌繍琛屽畨瑁呰剼鏈?
### 鎹?IP 鏃犳硶鐢熸晥

纭浜嬮」锛?1. 鏈哄櫒闇€瑕佹敮鎸?DHCP锛堝ぇ澶氭暟浜戞湇鍔″晢 VPS 鏀寔锛?2. 妫€鏌ユ帴鍙ｆ槸鍚︾湡鐨勮璋冪敤锛堟煡鐪嬫棩蹇楋級
3. DCHP 绉熺害鍙兘鏈湡姝ｉ噴鏀撅紝绋嶇瓑閲嶈瘯

## 馃搫 璁稿彲

MIT License
