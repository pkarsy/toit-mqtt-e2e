// edit "shared.toit" and put a unique 16-byte key

// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import mqtt-e2e show ntp-time MqttE2E
import .shared //show key pad-size
import monitor
import system
import log

module-name ::= "esp32x"

main:
  //
  start-time ::= Time.monotonic-us
  log.set-default (log.default.with-level log.INFO_LEVEL)
  //
  // The time should be corrected before the crypto works
  ntp-time
  //
  m := MqttE2E
      --key=encryption-key 
      --host=mqtt-host
      --pad-size=pad-size
      --publish-suffix="iot/" + module-name
      --subscribe-suffix=controller-suffix
      // --max-send-size
      // max-rcv-size
      // warn-size TODO
  //
  ch ::= monitor.Channel 5
  //
  task::
    while true:
      msg_:= ByteArray 0
      err := catch:
        msg_ = m.receive[1]
      if err:
        log.warn "Error in receiving : $err"
        continue
      cmd := msg_.to-string.trim
      //
      if cmd == "status":
        log.info "Got \"$cmd\""
        uptime := Duration --us=(Time.monotonic-us - start-time)
        ch.send "Name=$module-name\nUptime=$uptime\nFreemem = $system.process-stats[system.STATS-INDEX-SYSTEM-FREE-MEMORY]\ntemp=xyz"
      else if cmd=="ping":
        log.info "Got \"$cmd\", sending pong"
        ch.send "pong"
      else:
        log.info "Discarding unknown command \"$cmd\""
  //
  task::
    while true:
      msg := ch.receive
      // it can throw, so we protect it with a catch
      err := catch: m.send msg
      if err: print "Error : $err"