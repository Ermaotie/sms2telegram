local root = assert(arg[1], "source root required")
local t = dofile("tests/testlib.lua")
local core = dofile(root .. "/usr/lib/sms2telegram/core.lua")

t.eq("UCS2 Chinese", assert(core.ucs2_to_utf8("77ED4FE1")), "短信")
t.eq("UCS2 phone", assert(core.ucs2_to_utf8("002B0038003600310033")), "+8613")
local value, err = core.ucs2_to_utf8("D800")
t.eq("reject surrogate", value, nil)
t.truthy("surrogate error", err and err:match("surrogate"))
t.eq("UTF16 emoji pair", assert(core.ucs2_to_utf8("77EDD83DDE424FE1")), "短🙂信")
t.eq("isolated low surrogate rejected", core.ucs2_to_utf8("DC00"), nil)
t.eq("unpaired high surrogate rejected", core.ucs2_to_utf8("D8000041"), nil)
t.eq("maximum Unicode code point", assert(core.ucs2_to_utf8("DBFFDFFF")), string.char(244,143,191,191))
t.eq("UTF-8 length", core.utf8_length("A短信🙂"), 4)
local head, tail = core.utf8_prefix("A短信🙂B", 3)
t.eq("UTF-8 prefix", head, "A短信")
t.eq("UTF-8 remainder", tail, "🙂B")

local function rejects_invalid_utf8(name, text)
  local ok = pcall(function() core.utf8_length(text) end)
  t.eq(name, tostring(ok), "false")
end
rejects_invalid_utf8("invalid continuation", string.char(0xC2, 0x41))
rejects_invalid_utf8("truncated sequence", string.char(0xE2, 0x82))
rejects_invalid_utf8("overlong encoding", string.char(0xE0, 0x80, 0x80))
rejects_invalid_utf8("encoded surrogate", string.char(0xED, 0xA0, 0x80))
rejects_invalid_utf8("codepoint above Unicode", string.char(0xF4, 0x90, 0x80, 0x80))

local response = table.concat({
  '+CMGL: 7,"REC READ","002B0038003600310033003800300030003000300030003000300030",,"26/09/05,14:30:00+32"',
  '77ED4FE1000A7B2C4E8C884C',
  'OK',
  ''
}, '\r\n')
local messages = assert(core.parse_cmgl(response))
t.eq("one CMGL record", #messages, 1)
t.eq("CMGL index", messages[1].index, 7)
t.eq("decoded sender", messages[1].sender, "+8613800000000")
t.eq("legacy text body is not guessed as UCS2", messages[1].body,
  "77ED4FE1000A7B2C4E8C884C")

local live_response = table.concat({
  '+CMGL: 0,"REC READ","002B0038003600310033003800300030003000300030003000300030",,"26/09/06,21:05:00 +32"',
  'OpenWrt live SMS body',
  'OK',
  ''
}, '\r\n')
local live_messages = assert(core.parse_cmgl(live_response))
t.eq("live Air780 accepts SMS index zero", live_messages[1].index, 0)
t.eq("live Air780 header with timezone space", live_messages[1].timestamp, "26/09/06,21:05:00 +32")
t.eq("live Air780 raw UTF-8 body", live_messages[1].body, "OpenWrt live SMS body")

local invalid_utf8_response = table.concat({
  '+CMGL: 10,"REC READ","+8613800000000",,"26/09/06,21:06:00 +32"',
  string.char(0xff),
  'OK',
  ''
}, '\r\n')
local invalid_utf8_messages, invalid_utf8_err = core.parse_cmgl(invalid_utf8_response)
t.eq("invalid raw UTF-8 CMGL body rejected", invalid_utf8_messages, nil)
t.truthy("invalid raw UTF-8 CMGL body error", invalid_utf8_err and invalid_utf8_err:match("UTF%-8"))

local pdu_ucs2_response = table.concat({
  "+CMGL: 0,1,,24",
  "0891683108200105F0240D91683161450179F900082180904121102304611F8C22",
  "OK",
  ""
}, "\r\n")
local pdu_ucs2_messages = assert(core.parse_cmgl(pdu_ucs2_response))
t.eq("PDU UCS2 message count", #pdu_ucs2_messages, 1)
t.eq("PDU accepts index zero", pdu_ucs2_messages[1].index, 0)
t.eq("PDU decodes sender", pdu_ucs2_messages[1].sender, "+8613165410979")
t.eq("PDU decodes timestamp", pdu_ucs2_messages[1].timestamp, "12/08/09,14:12:01+32")
t.eq("PDU decodes UCS2 body", pdu_ucs2_messages[1].body, "感谢")

local pdu_gsm7_response = table.concat({
  "+CMGL: 1,0,,20",
  "00000491214300006290601250002305E8329BFD06",
  "OK",
  ""
}, "\r\n")
local pdu_gsm7_messages = assert(core.parse_cmgl(pdu_gsm7_response))
t.eq("PDU decodes GSM7 body", pdu_gsm7_messages[1].body, "hello")
t.eq("PDU unread status", pdu_gsm7_messages[1].status, "REC UNREAD")

local pdu_alpha_response = table.concat({
  "+CMGL: 2,1,,22",
  "000007D049A7F10900006290601250002305E8329BFD06",
  "OK",
  ""
}, "\r\n")
local pdu_alpha_messages = assert(core.parse_cmgl(pdu_alpha_response))
t.eq("PDU decodes alphanumeric sender", pdu_alpha_messages[1].sender, "INFO")
t.eq("PDU with alphanumeric sender keeps body alignment", pdu_alpha_messages[1].body, "hello")

local pdu_shifted_fallback_response = table.concat({
  "+CMGL: 4,1,,37",
  "000407D049A7F1096A00623110210000231620FBAECB41ECF739ED068DDFE4B20E1493CD6835",
  "OK",
  ""
}, "\r\n")
local shifted_fallback_messages, shifted_fallback_err = core.parse_cmgl(pdu_shifted_fallback_response)
t.truthy("PDU with shifted GSM7 body is recovered", shifted_fallback_messages, shifted_fallback_err)
t.eq("shifted GSM7 fallback keeps sender", shifted_fallback_messages and shifted_fallback_messages[1].sender,
  "INFO")
t.eq("shifted GSM7 fallback marks invalid timestamp",
  shifted_fallback_messages and shifted_fallback_messages[1].timestamp, "未知（原始短信时间异常）")
t.eq("shifted GSM7 fallback recovers body",
  shifted_fallback_messages and shifted_fallback_messages[1].body, "Your login code: 12345")

local pdu_low_confidence_fallback_response = table.concat({
  "+CMGL: 5,1,,23",
  "000407D049A7F109000062311021000023068542A1502800",
  "OK",
  ""
}, "\r\n")
local low_confidence_messages, low_confidence_err, low_confidence_rejected = core.parse_cmgl(pdu_low_confidence_fallback_response)
t.eq("timestamp does not discard standard GSM7 body", #assert(low_confidence_messages), 1)
t.eq("low-confidence record is not a transport error", low_confidence_err, nil)
t.eq("no speculative shifted recovery is needed", #low_confidence_rejected, 0)
t.eq("unknown timestamp is explicit", low_confidence_messages[1].timestamp, "未知（原始短信时间异常）")

local pdu_udhi_fallback_response = table.concat({
  "+CMGL: 6,1,,37",
  "004407D049A7F1096A00623110210000231620FBAECB41ECF739ED068DDFE4B20E1493CD6835",
  "OK",
  ""
}, "\r\n")
local udhi_fallback_messages, _, udhi_rejected = core.parse_cmgl(pdu_udhi_fallback_response)
t.eq("shifted fallback does not guess across UDH", #assert(udhi_fallback_messages), 0)
t.truthy("shifted UDH fallback reports malformed header",
  udhi_rejected[1].error:match("header"))

local pdu_empty_body_response = table.concat({
  "+CMGL: 7,1,,17",
  "000007D049A7F10900006290601250002300",
  "OK",
  ""
}, "\r\n")
local empty_body_messages, _, empty_rejected = core.parse_cmgl(pdu_empty_body_response)
t.eq("PDU with empty body is retained", #assert(empty_body_messages), 0)
t.truthy("PDU empty body reports body error", empty_rejected[1].error:match("body"))

-- A damaged but fully framed record cannot poison valid records before/after it.
local damaged_record = pdu_empty_body_response:gsub("CMGL: 7", "CMGL: 5"):gsub("OK\r\n$", "")
local valid_record = pdu_gsm7_response:gsub("OK\r\n$", "")
for _, mixed_pdu in ipairs({damaged_record .. valid_record, valid_record .. damaged_record}) do
  local valid, parse_err, rejected = core.parse_cmgl(mixed_pdu .. "OK\r\n")
  t.eq("mixed PDU has no framing error", parse_err, nil)
  t.eq("mixed PDU delivers valid record", #assert(valid), 1)
  t.eq("mixed PDU preserves valid body", valid[1].body, "hello")
  t.eq("mixed PDU identifies retained bad slot", rejected[1].index, 5)
  t.eq("mixed PDU counts rejected records", #rejected, 1)
end
local only_bad, _, only_bad_rejected = core.parse_cmgl(
  damaged_record .. pdu_empty_body_response)
t.eq("all undecodable records remain a successful scan", #assert(only_bad), 0)
t.eq("all undecodable records are reported", #only_bad_rejected, 2)
local malformed_length = valid_record:gsub(",,20", ",,21") .. damaged_record .. "OK\r\n"
t.eq("framing corruption still fails whole scan", core.parse_cmgl(malformed_length), nil)
t.eq("missing terminal still fails mixed scan", core.parse_cmgl(valid_record .. damaged_record), nil)

local pdu_mwi_ucs2_response = table.concat({
  "+CMGL: 3,1,,17",
  "00000491214300E062906012500023020041",
  "OK",
  ""
}, "\r\n")
local pdu_mwi_ucs2_messages = assert(core.parse_cmgl(pdu_mwi_ucs2_response))
t.eq("PDU MWI UCS2 coding group", pdu_mwi_ucs2_messages[1].body, "A")

local function incoming(dcs, data, udl, first, timestamp)
  local pdu = "00" .. (first or "00") .. "0491214300" .. dcs ..
    (timestamp or "62906012500023") .. string.format("%02X", udl) .. data
  return core.parse_cmgl("+CMGL: 3,0,," .. (#pdu / 2 - 1) .. "\r\n" .. pdu .. "\r\nOK\r\n")
end
local function gsm7(values, header)
  local bytes = header or {}
  local start = math.ceil(#bytes * 8 / 7) * 7
  for position, value in ipairs(values) do
    for bit = 0, 6 do
      local absolute = start + (position - 1) * 7 + bit
      local index = math.floor(absolute / 8) + 1
      bytes[index] = (bytes[index] or 0) + math.floor(value / 2^bit) % 2 * 2^(absolute % 8)
    end
  end
  local out = {}
  for _, value in ipairs(bytes) do out[#out+1] = string.format("%02X", value) end
  return table.concat(out), start / 7 + #values
end
local emoji_messages = assert(incoming("08", "77EDD83DDE424FE1", 8))
t.eq("PDU mixed Chinese emoji", emoji_messages[1].body, "短🙂信")
local bad_time_ucs2 = assert(incoming("08", "77ED4FE1", 4, nil, "62000012500023"))
t.eq("bad time preserves Chinese body", bad_time_ucs2[1].body, "短信")
t.truthy("bad time warning retained", bad_time_ucs2[1].warning:find("时间异常", 1, true))
local bad_time_gsm = assert(incoming("00", "E8329BFD06", 5, nil, "62000012500023"))
t.eq("bad time preserves short GSM7 body", bad_time_gsm[1].body, "hello")
local digits, digit_count = gsm7({49,50,51,52,53,54})
t.eq("short numeric code preserved with bad time",
  assert(incoming("00", digits, digit_count, nil, "62000012500023"))[1].body, "123456")
t.eq("automatic deletion DCS GSM7 is readable", assert(incoming("40", "E8329BFD06", 5))[1].body, "hello")
t.eq("automatic deletion DCS UCS2 is readable", assert(incoming("48", "77ED4FE1", 4))[1].body, "短信")
local _, _, compressed = incoming("60", "E8329BFD06", 5)
t.truthy("compressed data is not guessed", compressed[1].error:find("compressed", 1, true))
local extensions, extension_count = gsm7({27,20,27,40,27,41,27,47,27,60,27,61,27,62,27,64,27,101})
t.eq("GSM7 extension characters", assert(incoming("00", extensions, extension_count))[1].body, "^{}\\[~]|€")
local multipart, multipart_udl = gsm7({104,101,108,108,111}, {5,0,3,42,2,1})
local multipart_message = assert(incoming("00", multipart, multipart_udl, "40"))[1]
t.eq("concatenated GSM7 padding decoded", multipart_message.body, "hello")
t.truthy("concatenated segment order visible", multipart_message.warning:find("第 1/2 段", 1, true))
local ucs_segment = assert(incoming("08", "0500032A020177ED4FE1", 10, "40", "62000012500023"))[1]
t.eq("Chinese UDH with bad time keeps body", ucs_segment.body, "短信")
local _, _, bad_header = incoming("08", "0500042A020177ED4FE1", 10, "40")
t.truthy("invalid UDH element boundary is retained", bad_header[1].error:find("header", 1, true))
local utf8_8bit = assert(incoming("04", "E79FADE4BFA1", 6))[1]
t.eq("8-bit UTF8 text compatibility", utf8_8bit.body, "短信")
t.truthy("8-bit compatibility is labelled", utf8_8bit.warning:find("UTF-8", 1, true))
t.eq("8-bit ASCII class coding", assert(incoming("F4", "31323334", 4))[1].body, "1234")
local _, _, binary = incoming("04", "00FF1234", 4)
t.truthy("8-bit binary is not guessed as text", binary[1].error:find("8-bit", 1, true))
local _, _, port_message = incoming("04", "0605040B840B8431323334", 11, "40")
t.eq("port-addressed application data not mistaken for OTP", port_message[1].error, "binary application SMS")
local _, _, empty_invalid = incoming("00", "", 0, nil, "62000012500023")
t.eq("empty message with bad time reports empty body", empty_invalid[1].error, "empty PDU body")
t.eq("rejection preserves decoded sender", empty_invalid[1].sender, "+1234")
local anomaly_report = core.format_rejection(empty_invalid[1], "SM")
t.truthy("rejection reason in Chinese", anomaly_report:find("没有正文", 1, true))
t.truthy("rejection identifies slot", anomaly_report:find("SM / 3", 1, true))
t.eq("rejection never prints raw PDU", anomaly_report:find(empty_invalid[1].raw_pdu, 1, true), nil)
t.truthy("compatibility warning appended after body", core.format_parts(utf8_8bit, 4096)[1]:match("^短信\n\n"))

local numeric_text_response = table.concat({
  '+CMGL: 2,"REC READ","+8613800000000",,"26/09/06,21:06:00 +32"',
  "2026",
  "OK",
  ""
}, "\r\n")
t.eq("legacy text preserves hex-looking UTF-8", assert(core.parse_cmgl(numeric_text_response))[1].body,
  "2026")

local parts = core.format_parts(messages[1], 4096)
t.eq("short SMS one part", #parts, 1)
t.eq("body precedes metadata", parts[1],
  "77ED4FE1000A7B2C4E8C884C\n\n📩 短信信息\n来自：+8613800000000\n时间：26/09/05,14:30:00+32")
t.eq("route eth0", core.route_device("1.1.1.1 via 192.168.1.1 dev eth0 src 192.168.1.2\n"), "eth0")
t.eq("route eth2", core.route_device("1.1.1.1 dev eth2 src 10.0.0.2\n"), "eth2")
t.eq("missing route", core.route_device("RTNETLINK answers: Network unreachable\n"), nil)
t.eq("backoff starts", core.next_backoff(nil, 15, 300), 15)
t.eq("backoff doubles", core.next_backoff(60, 15, 300), 120)
t.eq("backoff caps", core.next_backoff(240, 15, 300), 300)

local long_message = {
  sender = "+8613800000000",
  timestamp = "26/09/05,14:30:00+32",
  body = string.rep("A", 4200)
}
local long_parts = core.format_parts(long_message, 4096)
local long_metadata = "📩 短信信息\n来自：+8613800000000\n时间：26/09/05,14:30:00+32"
t.truthy("long SMS splits", #long_parts > 1)
for i, part in ipairs(long_parts) do
  t.truthy("long part fits " .. i, core.utf8_length(part) <= 4096)
  t.eq("long part starts with body " .. i, part:sub(1, 1), "A")
  t.truthy("long part repeats metadata " .. i, part:find(long_metadata, 1, true))
end

local ok_body_response = table.concat({
  '+CMGL: 8,"REC READ","+8613800000000",,"26/09/05,14:31:00+32"',
  'first line',
  'OK',
  'last line',
  'OK',
  ''
}, '\r\n')
local ok_body_messages = assert(core.parse_cmgl(ok_body_response))
t.eq("preserves body OK line", ok_body_messages[1].body, "first line\nOK\nlast line")

local ten_part_message = {
  sender = "+8613800000000",
  timestamp = "26/09/05,14:30:00+32",
  body = string.rep("B", 40440)
}
local ten_parts = core.format_parts(ten_part_message, 4096)
t.truthy("two-digit multipart count", #ten_parts >= 10)
for i, part in ipairs(ten_parts) do
  t.eq("two-digit part fits " .. i, tostring(core.utf8_length(part) <= 4096), "true")
end
local mixed_response = table.concat({
  '+CMGL: 1,"STO UNSENT","+8613800000000",', '00610062',
  '+CMGL: 2,"STO SENT","+8613800000000",', '00630064',
  '+CMGL: 3,"REC READ",6,42,"+8613800000000",145,"26/09/05,14:30:00+32","26/09/05,14:31:00+32",0',
  '+CMGL: 4,"REC UNREAD","+8613800000000",,"26/09/05,14:32:00+32"', '004F004B',
  '+CMGL: 5,"REC READ","+8613800000000",,"26/09/05,14:33:00+32"', '',
  'OK', ''
}, '\r\n')
local mixed_messages = core.parse_cmgl(mixed_response)
t.eq("mixed CMGL returns incoming deliveries only", mixed_messages and #mixed_messages, 2)
t.eq("mixed CMGL preserves incoming index", mixed_messages and mixed_messages[1].index, 4)
t.eq("mixed CMGL preserves legacy hex-looking body", mixed_messages and mixed_messages[1].body,
  "004F004B")
t.eq("mixed CMGL preserves explicit blank incoming body", mixed_messages and mixed_messages[2] and mixed_messages[2].body, "")
local missing_body = '+CMGL: 6,"REC READ","+8613800000000",,"26/09/05,14:32:00+32"\r\nOK\r\n'
t.eq("incoming header without body is rejected", core.parse_cmgl(missing_body), nil)
local invalid_header = '+CMGL: 6,"REC READ",6,42,"not a timestamp"\r\n004F004B\r\nOK\r\n'
t.eq("REC status alone cannot identify SMS DELIVER", core.parse_cmgl(invalid_header), nil)
t.finish()
