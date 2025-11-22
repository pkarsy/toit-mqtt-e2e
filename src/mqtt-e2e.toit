/* 
mqtt-comm is based on top of mqtt package and offers some specialized functionality for easy
communication between IOT modules and the controller/logger

- mqtt-term : allows to "print" messages on any mqtt server. It can also
  receive messages/commands and pass it to the application


-mqtt-e2e : Should be used with on OPEN, no
  credentials, no TLS encryption mqtt broker. Every packet is encrypted BEFORE transmission
  and decrypted by the other party (End to End encryption).
  packets have a timestamp so no message reuse is possible(replay attacks)
  The AEAD encryption ensures no one can forge a fake message
  unless they know the key
  It offers a very easy to use communication platform,
  without the need to maintain a server account, no need to use certificates, or trust the server's
  security/confediality
  The 2 parties can connect and disconnect freely and the communication resumes
  (The messages are not repeated automatically this is a job of the application)
  By default pads the messages to specific size(default=50) so the length of the message
  is not revealed. The pad size should be a little larger than the largest message you exxpect to send
  Hiding the timing of the messages is a much harder problem and in fact cannot be solved by
  this library but but the app itself. Hopefully is something very rarelly needed.
  There is a function however to help on this. It is created as an experiment and may or may not
  help in this regard. The method send_fake "message" messages-number Duration burst_messages Duration
*/

import monitor
import system
import mqtt
import mqtt.packets show PublishPacket
import tls show RootCertificate
import crypto.aes show AesGcm
import crypto
import io show Buffer
import ntp
import esp32 show adjust_real_time_clock
import encoding.base64
import log

/* helper function. MqttE2E works 
only when the time is set with relativelly high precision.

Blocks until the first adjustment is ready, then returns
but spawns a task doing NTP every hour */
ntp-time --logger=log.default
    --refresh/Duration=(Duration --h=1)
    --server/string?=ntp.NTP-DEFAULT-SERVER-HOSTNAME
    --max-rtt/Duration=ntp.NTP-DEFAULT-MAX-RTT
    --port/int=ntp.NTP_DEFAULT_SERVER_PORT
    :
  result/ntp.Result? := null
  s/Lambda := ::
    //if server:
    result = ntp.synchronize --server=server --max-rtt=max-rtt --port=port
    //else:
    //  result = ntp.synchronize
    if result:
      adjust_real_time_clock result.adjustment
      logger.debug "NTP: adjustement=$result.adjustment"
    else:
      logger.info "NTP: synchronization request failed"
      sleep --ms=5000
  logger.debug "Waiting for the first NTP adjustment before return"
  while true:
    s.call
    if result:
      logger.debug "Got the first NTP fix, now a task will spawned"
      break
  task ::
    while true:
      if result:
        logger.debug "sleep for $refresh before the new NTP query"
        sleep refresh
      s.call

class MqttComm:
  send_chan_/monitor.Channel ::= ? //monitor.Channel 25
  mux_/monitor.Mutex ::= monitor.Mutex
  host_/string ::= ?
  port_/int ::= ?
  use_cert_/bool ::= ?
  publish-topic_/string ::= ?
  subscribe-topic_/string? ::= ?
  client_/mqtt.SimpleClient? := null // TODO full client
  options_/mqtt.SessionOptions ::= ?
  logger_/log.Logger ::= ?
  //
  constructor
      --host/string
      --port/int
      --cert/RootCertificate?=null
      --publish-topic/string?=null
      --subscribe-topic/string?=null
      --username/string?=null
      --password/string?=null
      --items/int=25
      --logger/log.Logger=log.default
      :
    logger_ = logger
    send_chan_ = monitor.Channel items
    host_ = host
    port_ = port
    publish-topic_ = publish-topic
    subscribe-topic_ = subscribe-topic
    if cert:
      cert.install
    use_cert_ = (cert != null)
    options_ = mqtt.SessionOptions
      --client-id="client-($random)"
      --clean-session=true
      --username=username
      --password=password
    mux_.do:
      newsession
    task::
      send_task_
  
  newsession msg_/string?=null:
    while true:
      err:=catch :
        transport := null
        if use-cert_:
          transport = mqtt.TcpTransport.tls --host=host_ --port=port_
            --server-name=host_
          //  transport := mqtt.TcpTransport.tls --host="10.5.2.187" --port=port_
          //  --server-name=host_
          // socat -x TCP-LISTEN:8883,fork TCP:mqtt.flespi.io:8883
        else:
          transport = mqtt.TcpTransport --host=host_ --port=port_
        client_ = mqtt.SimpleClient --transport=transport
        client_.receive
        client_.start --options=options_
      if err:
        logger_.trace "mqtt client connect err = $err"
        sleep --ms=5_000
      else:
        log.info "Connected to $host_:$port_"
        if subscribe-topic_:
          client_.subscribe subscribe-topic_
        if msg_==null: break
        err2 := catch : client_.publish publish-topic_ msg_
        if err2 == null:
          break
        logger_.info "The new session seems dead, cannot send the last message"
        client_.close
      
  send msg:
    send_chan_.send msg
    
  send_task_:
    while true:
      msg_ := send_chan_.receive
      mux_.do:
        err := catch: client_.publish publish-topic_ msg_
        if err:
          logger_.debug "MQTT publish : $err"
          client_.close
          sleep --ms=5_000
          newsession msg_
  
  receive -> PublishPacket?:
    pkt := client_.receive
    if pkt == null:
      mux_.do:
        logger_.info "Client is closed"
        client_.close
        sleep --ms=5_000
        newsession
      return null
    return pkt

// Up to 2^16 (65535) bytes messages
class MqttE2E:
  // some public servers
  static bevywise/string ::= "public-mqtt-broker.bevywise.com"
  static mosquitto/string ::= "test.mosquitto.org"
  static hivemq/string ::= "broker.hivemq.com"
  static emqx/string ::= "broker.emqx.io"
  static std-port/int ::= 1883
  // protocol constants
  static SIZE-FIELD-BYTES/int ::= 2
  static VERSION-FIELD-BYTES/int ::= 1
  static PROTOCOL_VERSION/int ::= 1
  // engine
  mqtt_/MqttComm ::= ?
  key_ ::= ?
  auth-data_/string ::= ?
  pad-size_ ::= ?
  // replay attacks protection
  last-msg_/Map := {:}
  logger_/log.Logger ::= ?
  //
  constructor
      --pad-size/int=50
      --port/int=std-port
      --host/string
      --auth-data/string="1234567812345678"
      --key/ByteArray
      --publish-suffix/string
      --subscribe-suffix/string
      --mqtt-comm/MqttComm?=null
      --logger/log.Logger=log.default
      :
    logger_ = logger
    if key.size != 16:
      throw "The key must be 16 bytes"
    key_ = key
    pad-size_ = pad-size // TODO 2 bytes
    if pad-size<0 or pad-size>int.MAX-U16 :
      throw "Invalid pad-size"
    auth-data_ = auth-data
    topic-base/string := generate-topic --key=key
    logger_.debug "base topic $topic-base"
    publish-topic := topic-base + "/" + publish-suffix
    subscribe-topic := topic-base + "/" + subscribe-suffix
    if mqtt-comm:
      print "Ignoring host and port, using preconfigured MqttComm"
      mqtt_ = mqtt-comm
    else:
      mqtt_ = MqttComm
          --host=host
          --port=port
          --publish-topic=publish-topic
          --subscribe-topic=subscribe-topic
      logger_.debug "Using $host:$port"
  
  send msg: // --warn-oversized/bool=false:
    start-time := Time.now
    part2/ByteArray? := null
    if msg is ByteArray:
      part2 = msg
    else if msg is string:
      part2 = msg.to-byte-array
    else:
      throw "The message can only be string/ByteArray"
    //
    part1/ByteArray := ByteArray (VERSION-FIELD-BYTES + SIZE-FIELD-BYTES)
    part1[0]= PROTOCOL_VERSION
    part1[1] = part2.size/256 // Big endian
    part1[2] = part2.size%256 // Big endian
    // This is the message size including possible padding
    // does not include Version(1byte) and SizeHeader(2 bytes)
    msg-size/int :=  max part2.size pad-size_
    if part2.size > pad-size_:
      logger_.warn "the message($msg-size bytes) is larger than the pad size"
    part3-size := max 0 (pad-size_ - part2.size)
    data := part1 + part2 + (ByteArray part3-size)
    enc-msg := encrypt Time.now.ns-since-epoch data
    // dt := t.to Time.now
    // logger_.debug "encrypt time = $dt"
    mqtt_.send enc-msg
  
  send-bogus msg
      --time-deviation/bool=false // the packets have future or past timestamp.
      --wrong-key/bool=false // correct topic but wrong key.
      --bogus-size/bool=false // the header contains a size not compatible with the actual packet size.
      :
    part2/ByteArray? := null
    if msg is ByteArray:
      part2 = msg
    else if msg is string:
      part2 = msg.to-byte-array
    else:
      throw "The message can only be string/ByteArray"
    part1/ByteArray? := ?
    msg-size-pad/int := (part2.size > pad-size_) ? part2.size : pad-size_
    part3/ByteArray := ?
    if msg-size-pad > pad-size_:
      logger_.warn "the message($msg-size-pad bytes) is larger than the pad size"
      part3 = #[]
    else:
      part3 = ByteArray (msg-size-pad - SIZE-FIELD-BYTES - part2.size )
    part1 = ByteArray SIZE-FIELD-BYTES
    part1[0] = part2.size/256 // Big endian
    part1[1] = part2.size%256 // Big endian
    data := part1 + part2 + part3
    enc-msg := encrypt Time.now.ns-since-epoch data
    if time-deviation:
      enc-msg[2]--
    else if wrong-key:
      enc-msg[15]++
    else if bogus-size:
      enc-msg[13]++
    mqtt_.send enc-msg

  receive -> List:
    enc := mqtt_.receive
    if enc==null:
      throw "Got null"
    topic:=enc.topic
    iv-time-ns/int := 0
    if true:
      iv/ByteArray := enc.payload[0..12] // TODO 8
      buffer/Buffer := Buffer iv
      iv-time-ns = buffer.big-endian.int64 --at=0
      if last-msg_.get enc.topic:
        prev-time := last-msg_[topic]
        if prev-time >= iv-time-ns:
          throw "The previous message has newer/identical timestamp"
      //iv-time-ns := buffer.big-endian.int64 --at=0 TODO all in E2E
      iv-time := (Time.epoch --ns=iv-time-ns)
      time-diff/Duration := iv-time.to Time.now
      if time-diff > (Duration --s=10):
        throw "The message is older then 10sec"
      if time-diff < (Duration --s=-10):
        throw "The message is coming from the future, 10sec or more"
    clear := decrypt enc.payload
    // topic := enc.topic
    // The encryption was valid, otherwise the previous throws
    packet-version := clear[0]
    if packet-version!= PROTOCOL_VERSION:
      throw "Packet version is unknown"
    header-reported-size := clear[1]*256+clear[2] // 2 byte Big Endian representation
    packet-data-pad-size := clear.size - SIZE-FIELD-BYTES
    if header-reported-size > packet-data-pad-size:
      throw "The packet is bogus. The header reports size larger than the packet itself"
    last-msg_[topic] = iv-time-ns
    return [topic, clear[3 .. header-reported-size + 3] ]
  
  encrypt ns-since-epoch/int data/ByteArray -> ByteArray:
    buffer ::= Buffer
    buffer.big-endian.write-int64 ns-since-epoch // 8 bytes
    buffer.write (crypto.random --size=4) // we pad 4 random bytes so the iv is 12 bytes
    iv/ByteArray := buffer.bytes  //#[1,2,3,4,5,6,7,8,9,10,11,12]
    encryptor/AesGcm := AesGcm.encryptor key_ iv
    enc-data := encryptor.encrypt data --authenticated-data=auth-data_
    buffer.write enc-data
    //e := iv + (enc.encrypt data --authenticated-data=auth-data_)
    encryptor.close
    return buffer.bytes

  decrypt e/ByteArray -> ByteArray:
    //t/Time:= Time.now
    e-iv/ByteArray := e[0..12]
    buffer/Buffer := Buffer e-iv
    //iv-time-ns := buffer.big-endian.int64 --at=0 TODO all in E2E
    //iv-time := (Time.epoch --ns=iv-time-ns)
    //time-diff/Duration := iv-time.to Time.now
    //if time-diff > (Duration --s=5):
    //  throw "The message is from the past"
    //if time-diff < (Duration --s=-5):
    //  throw "Time is coming from the future"
    e-e := e[12..e.size]
    dec/AesGcm := AesGcm.decryptor key_ e-iv
    // It can throw if the decryption fails
    d := dec.decrypt e-e --authenticated-data=auth-data_
    dec.close
    // we finally have a valid message
    //decr-time/Duration:= t.to Time.now
    //logger_.debug "Decrypt time = $decr-time"
    return d
  
generate-topic
    --key/ByteArray
    --length/int=12 // no need to be biggger
    --initial-iv/int='@' // no need to change, mainly for debugging
    --initial-msg/int='#' // the same
     -> string:

  if key.size != 16:
    throw "Key size is not 16 bytes"
  // a fake iv and message just to encrypt it and create the topic
  // from the key as a one way function
  iv/ByteArray := ByteArray 12 --initial=initial-iv
  msg/ByteArray := ByteArray 16 --initial=initial-msg
  enc/AesGcm := AesGcm.encryptor key iv
  topic-bin/ByteArray := enc.encrypt msg
  enc.close
  topic/string := base64.encode topic-bin
  topic = topic[0..12]
  topic = topic.replace --all "+" "a"
  topic = topic.replace --all "/" "b"
  topic = topic.replace --all "=" ""
  return topic

random-key -> ByteArray:
  // crypto.random generates random crypto secure messages
  k := (crypto.random --size=16)
  log.debug "key=$k size=$k.size"
  return k


    //iv-time-ns := buffer.big-endian.int64 --at=0 TODO all in E2E
    //iv-time := (Time.epoch --ns=iv-time-ns)
    //time-diff/Duration := iv-time.to Time.now
    //if time-diff > (Duration --s=5):
    //  throw "The message is from the past"
    //if time-diff < (Duration --s=-5):
    //  throw "Time is coming from the future"