/* CosmoACE dashboard panel for the Mainsail Panel Extender.
 *
 * A spool tile per slot (color + material) for each configured ACE, a
 * dryer section per unit with a drying
 * toggle (uses the addon's configured dry_temp_c/dry_minutes defaults)
 * plus custom temp/time, an ACE bypass toggle for manual spool prints
 * (ACE_SET_BYPASS → stock LOAD_FILAMENT / PRINT_START), and a slot editor
 * with a color wheel for manual (non-RFID) spools. Ported from the
 * CosmosWeb ACE component.
 *
 * Talks to the ace-addon CLI through RUN_SHELL_COMMAND CMD=ace_rpc; the
 * CLI prints JSON to the gcode console, which is read back from
 * moonraker's gcode_store. Manual slot info is stored in the moonraker
 * database (namespace "cosmoace"); the effective slot list is also
 * published to the "lane_data" namespace, which OrcaSlicer's
 * "Synchronize filament list from AMS" reads.
 *
 * While a print is running the panel does not inject gcode to query the
 * ACE; it shows the last cached state read-only instead.
 *
 * Safe without the Panel Extender: nothing loads this file. */
;(function () {
    if (!window.CosmosPanels) return

    var ACE_TYPES = ['PLA', 'PETG', 'ABS', 'ASA', 'TPU', 'HIPS', 'PC']
    var ACE_TEMP = {
        PLA: { n: 220, b: 60 }, PETG: { n: 245, b: 80 },
        ABS: { n: 255, b: 100 }, ASA: { n: 255, b: 100 },
        TPU: { n: 230, b: 50 }, HIPS: { n: 240, b: 100 },
        PC: { n: 270, b: 110 },
    }

    // aces[0] = main unit, aces[1] = a second chained unit when one is
    // configured. Slots number 1-4 on unit 0, 5-8 on unit 1.
    var ace = null, aces = [], err = '', busy = false, cur = -1, printing = false
    // online: this data was just queried. false + populated aces = last known
    // state from the db cache, shown read-only.
    var online = false
    var bypass = 0  // ACE_SET_BYPASS / _ACE_CONFIG.bypass
    var lastFull = 0   // last real (gcode) query, for the slow idle re-poll
    var dryDefaults = { t: 45, m: 240 } // from ace-addon.conf via status
    var slotCfgs = {} // manual slot info from the moonraker db
    var renderFn = null, pollTimer = null

    var esc = function (s) {
        return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;')
    }
    var hex = function (c) {
        return '#' + (Array.isArray(c) && c.length >= 3 ? c : [255, 255, 255])
            .slice(0, 3)
            .map(function (v) {
                return Math.max(0, Math.min(255, v | 0)).toString(16).padStart(2, '0')
            }).join('')
    }
    // dryer remain_time arrives in seconds
    var fmtRemain = function (sec) {
        sec = +sec || 0
        var h = Math.floor(sec / 3600), m = Math.round((sec % 3600) / 60)
        return h ? h + ' h ' + m + ' min' : m + ' min'
    }

    /* ---------------- color helpers ---------------- */
    function hsv2hex(h, s, v) {
        var f = function (n) {
            var k = (n + h / 60) % 6
            var c = v - v * s * Math.max(0, Math.min(k, 4 - k, 1))
            return Math.round(c * 255).toString(16).padStart(2, '0')
        }
        return '#' + f(5) + f(3) + f(1)
    }
    function hex2hsv(x) {
        var r = parseInt(x.slice(1, 3), 16) / 255
        var g = parseInt(x.slice(3, 5), 16) / 255
        var b = parseInt(x.slice(5, 7), 16) / 255
        var mx = Math.max(r, g, b), mn = Math.min(r, g, b), d = mx - mn
        var h = 0
        if (d) {
            if (mx === r) h = 60 * (((g - b) / d) % 6)
            else if (mx === g) h = 60 * ((b - r) / d + 2)
            else h = 60 * ((r - g) / d + 4)
        }
        if (h < 0) h += 360
        return { h: h, s: mx ? d / mx : 0, v: mx }
    }

    /* ---------------- minimal modal ---------------- */
    function openModal(html) {
        var ov = document.createElement('div')
        ov.style.cssText =
            'position:fixed;inset:0;z-index:200;background:rgba(0,0,0,.55);' +
            'display:flex;align-items:center;justify-content:center'
        var dark = !document.querySelector('.v-application.theme--light')
        var card = document.createElement('div')
        card.className = 'v-card v-sheet ' + (dark ? 'theme--dark' : 'theme--light')
        card.style.cssText =
            'width:340px;max-width:92vw;border-radius:8px;padding:20px'
        card.innerHTML = html
        ov.appendChild(card)
        ov.onmousedown = function (e) { if (e.target === ov) close() }
        function close() { ov.remove() }
        // inside .v-application, so Vuetify utility classes apply
        ;(document.querySelector('.v-application') || document.body).appendChild(ov)
        return { el: card, close: close }
    }

    /* ---------------- slot info ---------------- */
    // The ACE only reports real data for RFID-tagged spools; manual
    // spools live in the moonraker db instead.
    function slotInfo(n, s) {
        var stored = slotCfgs[n] || {}
        var tagged = !!(s && s.type)
        return {
            tagged: tagged,
            type: tagged ? s.type : (stored.type || ''),
            color: tagged ? hex(s.color) : (stored.color || ''),
            sku: (s && s.sku) || '',
        }
    }

    // slot n (1-8) -> that unit's slot status object, or null
    function slotAt(n) {
        var a = aces[Math.floor((n - 1) / 4)]
        return (a && a.slots && a.slots[(n - 1) % 4]) || null
    }
    function slotCount() { return Math.max(1, aces.length) * 4 }

    var lastPub = ''
    function publishLanes(ctx) {
        var lanes = {}
        for (var i = 0; i < slotCount(); i++) {
            var info = slotInfo(i + 1, slotAt(i + 1))
            var t = ACE_TEMP[info.type] || {}
            var lane = {
                lane: String(i),
                material: info.type || '',
                color: info.type && info.color
                    ? info.color.replace('#', '').toUpperCase() : '',
            }
            if (info.type && t.n) { lane.nozzle_temp = t.n; lane.bed_temp = t.b }
            lanes['lane' + (i + 1)] = lane
        }
        var s = JSON.stringify(lanes)
        if (s === lastPub) return
        lastPub = s
        Promise.all(Object.keys(lanes).map(function (k) {
            return ctx.apiPost('/server/database/item', {
                namespace: 'lane_data', key: k, value: lanes[k],
            })
        })).catch(function () { lastPub = '' }) // retry on the next change
    }

    /* ---------------- status refresh ---------------- */
    // Preferred source: the compact status the CLI caches in the moonraker db
    // every time it is asked - a plain GET, no gcode, so it still works
    // mid-print. Anything older than this is shown as last known state.
    function applyStatus(st, fallbackErr) {
        if (st.units) {
            aces = Object.keys(st.units).sort().map(function (u) {
                return st.units[u].ace_status || null
            })
        } else {
            aces = [st.ace_status || null]
        }
        ace = aces[0] || null
        var d = st.defaults || {}
        if (d.dry_temp_c) dryDefaults.t = d.dry_temp_c
        if (d.dry_minutes) dryDefaults.m = d.dry_minutes
        if (ace) {
            err = ''   // recovered: don't leave a stale message on screen
        } else {
            err = (st.units && st.units['0'] && st.units['0'].last_error) ||
                (st.transport && st.transport.last_error) ||
                fallbackErr || 'ACE not responding'
        }
    }
    function readDb(ctx) {
        return ctx.apiGet('/server/database/item?namespace=cosmoace&key=status')
            .then(function (r) {
                var v = (r.result && r.result.value) || {}
                if (!v.units) return false
                // Age of the cache says when it was last written, NOT whether
                // the ACE is reachable - nothing writes it on a timer. So a
                // stale entry must never flip the panel to "offline"; it only
                // means we should go ask again. Keep whatever `online` the
                // last real query established.
                var stale = v.updated_unix &&
                    Date.now() / 1000 - v.updated_unix > 30
                applyStatus(v, '')
                if (!stale) online = true
                return stale ? 'stale' : 'fresh'
            })
            .catch(function () { return false })
    }
    // Fallback: run "ace_rpc panel-status" and read the JSON it prints from
    // the gcode_store. Skipped while printing - injecting gcode mid-print
    // stalls the queue briefly, and the db path covers that case.
    function refresh(ctx) {
        if (busy) return
        busy = true
        lastFull = Date.now()
        err = ''
        renderFn && renderFn()
        queryPrinter(ctx).then(function () {
            return readDb(ctx).then(function (got) {
                if (got === 'fresh' || printing) return
                var t0 = 0
                return ctx.apiGet('/server/gcode_store?count=1')
                    .then(function (r) {
                        var e = (r.result.gcode_store || [])[0]
                        t0 = e ? e.time : 0
                        return ctx.gcode(
                            'RUN_SHELL_COMMAND CMD=ace_rpc PARAMS="panel-status"')
                    })
                    .then(function () { return pollStore(ctx, t0, Date.now() + 15000) })
                    .then(function (j) { applyStatus(j.status || {}, j.error); online = !!ace })
                    // keep any last-known state from the stale db mirror
                    .catch(function (e) { online = false; if (!err) err = e.message || String(e) })
            })
        }).then(function () {
            busy = false
            renderFn && renderFn()
            publishLanes(ctx)
        })
    }

    function pollStore(ctx, t0, deadline) {
        return ctx.apiGet('/server/gcode_store?count=100').then(function (r) {
            var txt = '', started = false, depth = 0
            var entries = (r.result.gcode_store || []).filter(function (e) {
                return e.time > t0 && e.type === 'response'
            })
            for (var i = 0; i < entries.length; i++) {
                var lines = entries[i].message.split('\n')
                for (var k = 0; k < lines.length; k++) {
                    var line = lines[k].replace(/^\/\/\s?/, '')
                    if (!started) {
                        if (!line.trim().startsWith('{')) continue
                        started = true
                    }
                    txt += line + '\n'
                    depth += (line.match(/\{/g) || []).length -
                        (line.match(/\}/g) || []).length
                    if (started && depth <= 0) return JSON.parse(txt)
                }
            }
            if (Date.now() > deadline) throw new Error('No reply from the ACE addon')
            return new Promise(function (res) { setTimeout(res, 700) })
                .then(function () { return pollStore(ctx, t0, deadline) })
        })
    }

    // active slot + print state + ACE bypass, for highlighting and locks
    function queryPrinter(ctx) {
        return ctx.apiGet(
            '/printer/objects/query?gcode_macro%20_ACE_STATE&gcode_macro%20_ACE_CONFIG&print_stats'
        ).then(function (r) {
            var st = r.result.status || {}
            cur = (st['gcode_macro _ACE_STATE'] || {}).current_slot
            if (cur == null) cur = -1
            var cfg = st['gcode_macro _ACE_CONFIG'] || {}
            bypass = cfg.bypass|0
            printing = ['printing', 'paused'].indexOf(
                (st.print_stats || {}).state) >= 0
        }).catch(function () { /* klippy not ready */ })
    }

    /* ---------------- spool svg ---------------- */
    function spoolSvg(color) {
        if (!color)
            return '<svg viewBox="0 0 48 48" class="cosmoace-spool">' +
                '<circle cx="24" cy="24" r="19" fill="none" ' +
                'stroke="rgba(128,128,128,.4)" stroke-width="2" stroke-dasharray="5 4"/>' +
                '<circle cx="24" cy="24" r="7" fill="none" ' +
                'stroke="rgba(128,128,128,.4)" stroke-width="2"/></svg>'
        return '<svg viewBox="0 0 48 48" class="cosmoace-spool">' +
            '<circle cx="24" cy="24" r="20" fill="' + color + '"/>' +
            '<circle cx="24" cy="24" r="20" fill="none" stroke="rgba(0,0,0,.25)" stroke-width="1.5"/>' +
            // winding hint
            '<circle cx="24" cy="24" r="15" fill="none" stroke="rgba(0,0,0,.12)" stroke-width="1"/>' +
            '<circle cx="24" cy="24" r="11" fill="none" stroke="rgba(0,0,0,.12)" stroke-width="1"/>' +
            // hub
            '<circle cx="24" cy="24" r="7.5" fill="rgba(0,0,0,.45)"/>' +
            '<circle cx="24" cy="24" r="3.5" fill="rgba(255,255,255,.25)"/></svg>'
    }

    /* ---------------- slot editor (color wheel + material) ---------------- */
    function slotModal(ctx, n, s) {
        var info = slotInfo(n, s)
        var color = /^#[0-9a-fA-F]{6}$/.test(info.color) ? info.color : '#808080'
        var type = info.type || 'PLA'
        var hsv = hex2hsv(color)
        var m = openModal(
            '<div class="d-flex align-center mb-3" style="gap:12px">' +
            spoolSvg(color).replace('class="cosmoace-spool"',
                'data-preview style="width:42px;height:42px;flex:0 0 auto"') +
            '<div><div style="font-size:1.05rem;font-weight:500">Slot ' + n + '</div>' +
            '<div style="opacity:.6;font-size:.78rem" data-hex>' + color +
            (info.sku ? ' · ' + esc(info.sku) : '') + '</div></div></div>' +
            (info.tagged
                ? '<p style="opacity:.65;font-size:.8rem;margin-bottom:12px">' +
                  'RFID spool — color and material come from the tag and ' +
                  'can’t be edited here.</p>'
                : '<div style="opacity:.6;font-size:.75rem;margin-bottom:6px">COLOR</div>' +
                  '<div style="position:relative;margin-bottom:10px">' +
                  '<div data-sq style="height:140px;border-radius:6px;cursor:crosshair"></div>' +
                  '<div data-sqmark style="position:absolute;width:12px;height:12px;' +
                  'border:2px solid #fff;border-radius:50%;pointer-events:none;' +
                  'box-shadow:0 0 3px rgba(0,0,0,.8);transform:translate(-50%,-50%)"></div>' +
                  '</div>' +
                  '<div style="position:relative;margin-bottom:10px">' +
                  '<div data-hue style="height:14px;border-radius:7px;cursor:crosshair;' +
                  'background:linear-gradient(to right,#f00,#ff0,#0f0,#0ff,#00f,#f0f,#f00)"></div>' +
                  '<div data-huemark style="position:absolute;top:50%;width:14px;height:14px;' +
                  'border:2px solid #fff;border-radius:50%;pointer-events:none;' +
                  'box-shadow:0 0 3px rgba(0,0,0,.8);transform:translate(-50%,-50%)"></div>' +
                  '</div>' +
                  '<div class="d-flex" style="gap:6px;margin-bottom:14px">' +
                  ['#f44336', '#4caf50', '#2196f3', '#ffeb3b', '#000000', '#ffffff']
                      .map(function (c) {
                          return '<button data-preset="' + c + '" style="flex:1;height:24px;' +
                              'border-radius:4px;border:1px solid rgba(128,128,128,.4);' +
                              'background:' + c + ';cursor:pointer"></button>'
                      }).join('') + '</div>') +
            (info.tagged ? '' :
                '<div style="opacity:.6;font-size:.75rem;margin-bottom:6px">MATERIAL</div>' +
                '<div class="d-flex" style="flex-wrap:wrap;gap:6px;margin-bottom:18px">' +
                ACE_TYPES.map(function (t) {
                    return '<button data-type="' + t + '" class="cosmoace-mchip' +
                        (t === type ? ' sel' : '') + '">' + t + '</button>'
                }).join('') + '</div>') +
            '<div class="d-flex" style="gap:8px">' +
            (info.tagged ? '' :
                '<button data-save class="v-btn v-btn--outlined v-size--small primary--text">Save</button>') +
            '<span style="flex:1"></span>' +
            '<button data-close class="v-btn v-btn--text v-size--small">Cancel</button>' +
            '</div>'
        )

        var hexLbl = m.el.querySelector('[data-hex]')
        var preview = m.el.querySelector('[data-preview]')
        function applyPreview() {
            color = hsv2hex(hsv.h, hsv.s, hsv.v)
            hexLbl.textContent = color + (info.sku ? ' · ' + info.sku : '')
            var circles = preview.querySelectorAll('circle')
            if (circles.length > 1) circles[0].setAttribute('fill', color)
        }

        var sq = m.el.querySelector('[data-sq]')
        if (sq) {
            var sqMark = m.el.querySelector('[data-sqmark]')
            var hue = m.el.querySelector('[data-hue]')
            var hueMark = m.el.querySelector('[data-huemark]')
            // saturation left->right, brightness top->bottom, for the hue
            function paint() {
                sq.style.background =
                    'linear-gradient(to top, #000, transparent), ' +
                    'linear-gradient(to right, #fff, ' + hsv2hex(hsv.h, 1, 1) + ')'
                sqMark.style.left = hsv.s * 100 + '%'
                sqMark.style.top = (1 - hsv.v) * 100 + '%'
                sqMark.style.background = hsv2hex(hsv.h, hsv.s, hsv.v)
                hueMark.style.left = (hsv.h / 360) * 100 + '%'
                hueMark.style.background = hsv2hex(hsv.h, 1, 1)
            }
            paint()
            function drag(el, fn) {
                el.onpointerdown = function (e) {
                    try { el.setPointerCapture(e.pointerId) } catch (x) { /* ok */ }
                    fn(e)
                    el.onpointermove = fn
                }
                el.onpointerup = function () { el.onpointermove = null }
            }
            drag(sq, function (e) {
                var r = sq.getBoundingClientRect()
                hsv.s = Math.min(1, Math.max(0, (e.clientX - r.left) / r.width))
                hsv.v = Math.min(1, Math.max(0, 1 - (e.clientY - r.top) / r.height))
                paint()
                applyPreview()
            })
            drag(hue, function (e) {
                var r = hue.getBoundingClientRect()
                hsv.h = Math.min(359.9, Math.max(0,
                    (e.clientX - r.left) / r.width * 360))
                paint()
                applyPreview()
            })
            m.el.querySelectorAll('[data-preset]').forEach(function (b) {
                b.onclick = function () {
                    hsv = hex2hsv(b.dataset.preset)
                    paint()
                    applyPreview()
                }
            })
        }

        m.el.querySelectorAll('[data-type]').forEach(function (b) {
            b.onclick = function () {
                type = b.dataset.type
                m.el.querySelectorAll('[data-type]').forEach(function (x) {
                    x.classList.toggle('sel', x === b)
                })
            }
        })
        var save = m.el.querySelector('[data-save]')
        if (save) save.onclick = function () {
            slotCfgs[n] = slotCfgs[n] || {}
            slotCfgs[n].type = type
            slotCfgs[n].color = color
            ctx.apiPost('/server/database/item', {
                namespace: 'cosmoace', key: 'slots', value: slotCfgs,
            }).catch(function () {})
            // also offer it to the ACE — honored if a future firmware accepts it
            ctx.gcode('ACE_SET_FILAMENT SLOT=' + n + ' TYPE=' + type +
                ' COLOR=' + color.replace('#', '').toUpperCase())
                .catch(function () {})
            publishLanes(ctx)
            m.close()
            renderFn && renderFn()
        }
        m.el.querySelector('[data-close]').onclick = m.close
    }

    /* ---------------- panel ---------------- */
    window.CosmosPanels.register({
        id: 'cosmoace',
        title: 'ACE Pro',
        // mdi-view-grid: four squares, one per slot
        icon: 'M3,11H11V3H3M3,21H11V13H3M13,21H21V13H13M13,3V11H21V3',
        buttons: [
            {
                // mdi-refresh
                icon: 'M17.65,6.35C16.2,4.9 14.21,4 12,4A8,8 0 0,0 4,12A8,8 0 0,0 12,20C15.73,20 18.84,17.45 19.73,14H17.65C16.83,16.33 14.61,18 12,18A6,6 0 0,1 6,12A6,6 0 0,1 12,6C13.66,6 15.14,6.69 16.22,7.78L13,11H20V4L17.65,6.35Z',
                onClick: function (ctx) { refresh(ctx) },
            },
            {
                // mdi-dots-vertical
                icon: 'M12,16A2,2 0 0,1 14,18A2,2 0 0,1 12,20A2,2 0 0,1 10,18A2,2 0 0,1 12,16M12,10A2,2 0 0,1 14,12A2,2 0 0,1 12,14A2,2 0 0,1 10,12A2,2 0 0,1 12,10M12,4A2,2 0 0,1 14,6A2,2 0 0,1 12,8A2,2 0 0,1 10,6A2,2 0 0,1 12,4Z',
                menu: function (el, ctx) {
                    var b = document.createElement('button')
                    b.className = 'v-btn v-btn--text v-size--small'
                    b.textContent = 'Copy slots for Orca'
                    b.onclick = function () {
                        var txt = []
                        for (var i = 0; i < slotCount(); i++) {
                            var info = slotInfo(i + 1, slotAt(i + 1))
                            txt.push('T' + i + ': ' + (info.color || '#000000') +
                                ' ' + (info.type || 'empty'))
                        }
                        navigator.clipboard && navigator.clipboard.writeText(txt.join('\n'))
                    }
                    el.appendChild(b)
                },
            },
        ],
        mount: function (el, ctx) {
            el.innerHTML =
                '<style>' +
                '.cosmoace-slots{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;margin:4px 0 12px}' +
                '.cosmoace-slot{display:flex;flex-direction:column;align-items:center;gap:4px;' +
                'padding:12px 4px 9px;background:rgba(128,128,128,.06);' +
                'border:1px solid rgba(128,128,128,.18);border-radius:8px;' +
                'cursor:pointer;font-size:.76rem;transition:background .15s,border-color .15s}' +
                '.cosmoace-slot:hover{background:rgba(128,128,128,.14)}' +
                '.cosmoace-slot.active{border-color:var(--v-primary-base,#2196f3)}' +
                '.cosmoace-slot.locked{cursor:default;opacity:.65}' +
                '.cosmoace-slot.locked:hover{background:rgba(128,128,128,.06)}' +
                '.cosmoace-spool{width:40px;height:40px}' +
                '.cosmoace-chip{padding:1px 10px;border-radius:10px;font-size:.72rem;' +
                'background:rgba(128,128,128,.2)}' +
                '.cosmoace-chip.ok{background:rgba(76,175,80,.25)}' +
                '.cosmoace-chip.print{background:rgba(33,150,243,.25)}' +
                '.cosmoace-row{display:flex;align-items:center;gap:8px;flex-wrap:wrap}' +
                '.cosmoace-dryer{border-top:1px solid rgba(128,128,128,.18);' +
                'padding-top:10px;margin-top:2px}' +
                '.cosmoace-dryer+.cosmoace-dryer{margin-top:12px}' +
                '.cosmoace-dtitle{font-size:.82rem;margin-bottom:8px}' +
                '.cosmoace-dtitle b{font-weight:500}' +
                '.cosmoace-btn{padding:3px 10px;font-size:.72rem;border-radius:4px;' +
                'border:1px solid rgba(128,128,128,.35);background:transparent;' +
                'color:inherit;cursor:pointer;transition:background .15s}' +
                '.cosmoace-btn:hover:not(:disabled){background:rgba(128,128,128,.15)}' +
                '.cosmoace-btn:disabled{opacity:.4;cursor:default}' +
                '.cosmoace-field{display:inline-flex;align-items:center;gap:4px;' +
                'border:1px solid rgba(128,128,128,.35);border-radius:4px;padding:3px 8px}' +
                '.cosmoace-field input{width:34px;border:none;outline:none;' +
                'background:transparent;color:inherit;font-size:.74rem;' +
                'text-align:right;-moz-appearance:textfield;appearance:textfield}' +
                '.cosmoace-field input::-webkit-outer-spin-button,' +
                '.cosmoace-field input::-webkit-inner-spin-button' +
                '{-webkit-appearance:none;margin:0}' +
                '.cosmoace-field span{opacity:.6;font-size:.7rem}' +
                '.cosmoace-mchip{padding:3px 10px;font-size:.74rem;border-radius:12px;' +
                'border:1px solid rgba(128,128,128,.35);background:transparent;' +
                'color:inherit;cursor:pointer}' +
                '.cosmoace-mchip.sel{border-color:var(--v-primary-base,#2196f3);' +
                'color:var(--v-primary-base,#2196f3)}' +
                '.cosmoace-mchip:disabled{opacity:.45;cursor:default}' +
                '.cosmoace-note{opacity:.6;font-size:.78rem;margin:2px 0 8px}' +
                '.cosmoace-unitlbl{opacity:.55;font-size:.7rem;letter-spacing:.08em;' +
                'text-transform:uppercase;margin:6px 0 2px}' +
                '.cosmoace-tgl{position:relative;width:34px;height:18px;flex:0 0 auto;' +
                'border-radius:9px;background:rgba(128,128,128,.35);cursor:pointer;' +
                'border:none;padding:0;transition:background .2s}' +
                '.cosmoace-tgl:after{content:"";position:absolute;top:2px;left:2px;' +
                'width:14px;height:14px;border-radius:50%;background:#fff;transition:left .2s}' +
                '.cosmoace-tgl.on{background:var(--v-primary-base,#2196f3)}' +
                '.cosmoace-tgl.on:after{left:18px}' +
                '.cosmoace-tgl:disabled{opacity:.4;cursor:default}' +
                '</style>' +
                '<div data-body><p class="cosmoace-note">Loading…</p></div>'
            var body = el.querySelector('[data-body]')

            renderFn = function () {
                var units = Math.max(1, aces.length)
                var multi = units > 1
                var u, i

                // keep user-typed custom values across re-renders (per unit)
                var vals = []
                for (u = 0; u < units; u++) {
                    var pT = body.querySelector('[data-ct="' + u + '"]')
                    var pM = body.querySelector('[data-cm="' + u + '"]')
                    vals.push({
                        t: pT && pT.value ? pT.value : dryDefaults.t,
                        m: pM && pM.value ? pM.value : dryDefaults.m,
                    })
                }

                var chip = printing
                    ? '<span class="cosmoace-chip print">printing</span>'
                    : bypass
                        ? '<span class="cosmoace-chip">bypass</span>'
                    : '<span class="cosmoace-chip ' + (online && ace ? 'ok' : '') + '">' +
                      (online && ace ? esc(ace.status || 'ready') : busy ? '…' : 'offline') +
                      '</span>'
                var html =
                    '<div class="cosmoace-row" style="margin-bottom:6px">' + chip +
                    (cur >= 1 ? '<span class="cosmoace-note" style="margin:0">active: slot ' + cur + '</span>' : '') +
                    (busy ? '<span class="cosmoace-note" style="margin:0">refreshing…</span>' : '') +
                    '</div>' +
                    (printing
                        ? '<p class="cosmoace-note">A print is running — controls are ' +
                          'locked until it finishes.</p>'
                        : err && !online
                            ? '<p class="cosmoace-note">' + esc(err) + '</p>'
                            : '')

                for (u = 0; u < units; u++) {
                    if (multi)
                        html += '<div class="cosmoace-unitlbl">ACE ' + (u + 1) +
                            (aces[u] ? '' : ' — offline') + '</div>'
                    html += '<div class="cosmoace-slots">'
                    for (i = 0; i < 4; i++) {
                        var n = u * 4 + i + 1
                        // no data for this unit (connecting / never seen):
                        // empty spools, not the saved manual colors
                        var info = aces[u]
                            ? slotInfo(n, slotAt(n))
                            : { tagged: false, type: '', color: '', sku: '' }
                        html += '<div class="cosmoace-slot' +
                            (cur === n ? ' active' : '') +
                            (printing ? ' locked' : '') +
                            '" data-slot="' + n + '" title="Slot ' + n +
                            (printing ? '' : ' — click to edit') + '">' +
                            spoolSvg(info.color) +
                            '<span>' + esc(info.type || '—') + (info.tagged ? ' ⦿' : '') + '</span>' +
                            '</div>'
                    }
                    html += '</div>'
                }

                for (u = 0; u < units; u++) {
                    var a = aces[u] || null
                    var dryer = (a && (a.dryer_status || a.dryer)) || {}
                    var drying = String(dryer.status || '').toLowerCase() === 'drying'
                    var lock = printing || !a || !online
                    html +=
                        '<div class="cosmoace-dryer">' +
                        '<div class="cosmoace-dtitle">' +
                        (multi ? 'ACE ' + (u + 1) + ' dryer ' : 'Dryer ') +
                        (drying
                            ? '<b>' + esc(dryer.target_temp) + '°C</b>/<b>' +
                              (a && a.temp != null ? esc(a.temp) : '–') +
                              '°C</b> — ' + fmtRemain(dryer.remain_time)
                            : '— off') + '</div>' +
                        '<div class="cosmoace-row">' +
                        '<span style="font-size:.78rem">Drying</span>' +
                        '<label class="cosmoace-field"><input data-ct="' + u + '" type="number" ' +
                        'min="35" max="65" value="' + vals[u].t + '"' +
                        (drying ? ' disabled' : '') + '><span>°C</span></label>' +
                        '<label class="cosmoace-field"><input data-cm="' + u + '" type="number" ' +
                        'min="10" max="1440" value="' + vals[u].m + '"' +
                        (drying ? ' disabled' : '') + '><span>min</span></label>' +
                        '<button data-drytgl="' + u + '" class="cosmoace-tgl' + (drying ? ' on' : '') + '"' +
                        (lock ? ' disabled' : '') + ' title="' +
                        (drying ? 'Stop drying' : 'Start drying') + '"></button>' +
                        '</div></div>'
                }

                // ACE bypass is global (one virtual switch for all units), so
                // it gets its own section after the per-unit dryers.
                html +=
                    '<div class="cosmoace-dryer">' +
                    '<div class="cosmoace-dtitle">ACE bypass ' +
                    (bypass ? '<b>on</b> — manual spool' : '— off') + '</div>' +
                    '<div class="cosmoace-row">' +
                    '<span style="font-size:.78rem">Bypass</span>' +
                    '<button data-bypasstgl class="cosmoace-tgl' + (bypass ? ' on' : '') + '"' +
                    (printing ? ' disabled' : '') +
                    ' title="' + (bypass
                        ? 'Bypass on — hub ignored; toolhead runout still active if fitted'
                        : 'Bypass off — CosmoACE active (click for manual spool)') +
                    '"></button>' +
                    '<span class="cosmoace-note" style="margin:0">' +
                    (bypass ? 'hub ignored / manual spool' : 'ACE macros active') +
                    '</span></div></div>'
                body.innerHTML = html

                if (!printing)
                    body.querySelectorAll('[data-slot]').forEach(function (d) {
                        d.onclick = function () {
                            var n = +d.dataset.slot
                            slotModal(ctx, n, slotAt(n))
                        }
                    })
                body.querySelectorAll('[data-drytgl]').forEach(function (tgl) {
                    tgl.onclick = function () {
                        var tu = +tgl.dataset.drytgl
                        var ta = aces[tu] || null
                        var td = (ta && (ta.dryer_status || ta.dryer)) || {}
                        if (String(td.status || '').toLowerCase() === 'drying') {
                            ctx.gcode('RUN_SHELL_COMMAND CMD=ace_rpc PARAMS="dry-stop ' + tu + '"')
                                .catch(function () {})
                        } else {
                            var t = parseFloat(body.querySelector('[data-ct="' + tu + '"]').value) || dryDefaults.t
                            var m2 = parseFloat(body.querySelector('[data-cm="' + tu + '"]').value) || dryDefaults.m
                            ctx.gcode('RUN_SHELL_COMMAND CMD=ace_rpc PARAMS="dry-start ' +
                                Math.min(65, Math.max(35, t)) + ' ' +
                                Math.min(1440, Math.max(10, m2)) + ' 7000 ' + tu + '"')
                                .catch(function () {})
                        }
                        setTimeout(function () { refresh(ctx) }, 2500)
                        tgl.classList.toggle('on')
                        tgl.disabled = true
                    }
                })
                var bypassTgl = body.querySelector('[data-bypasstgl]')
                if (bypassTgl && !printing) {
                    bypassTgl.onclick = function () {
                        var next = bypass ? 0 : 1
                        bypassTgl.disabled = true
                        bypassTgl.classList.toggle('on', !!next)
                        ctx.gcode('ACE_SET_BYPASS ENABLE=' + next)
                            .then(function () {
                                bypass = next
                                renderFn && renderFn()
                            })
                            .catch(function () {
                                bypassTgl.classList.toggle('on', !!bypass)
                                bypassTgl.disabled = false
                            })
                    }
                }
            }

            // light poll: printing state + active slot, plus a db read so
            // status stays live during prints (dryer countdown, colors).
            // Re-render only on change - a rebuild stomps half-typed inputs.
            var lastPoll = ''
            function lightPoll() {
                var was = printing
                queryPrinter(ctx).then(function () {
                    if (was !== printing && !printing) { refresh(ctx); return }
                    // While idle, re-query for real every 2 min: keeps the db
                    // cache warm for a page load mid-print, picks up spool
                    // swaps, and notices an unplugged ACE. Slow on purpose -
                    // each one logs a line in the gcode console.
                    if (!printing && Date.now() - lastFull > 120000) {
                        lastFull = Date.now()
                        refresh(ctx)
                        return
                    }
                    readDb(ctx).then(function () {
                        var s = JSON.stringify(aces) + '|' + printing + '|' + cur + '|' + online + '|' + bypass
                        if (s !== lastPoll) {
                            lastPoll = s
                            renderFn && renderFn()
                        }
                    })
                })
            }

            // CosmoACE installed? (guards against a stale panel file)
            function boot() {
                ctx.apiGet('/printer/objects/list').then(function (r) {
                    if ((r.result.objects || []).indexOf('gcode_macro ACE_STATUS') < 0) {
                        body.innerHTML =
                            '<p class="cosmoace-note">CosmoACE not detected — install ' +
                            'the cosmoace-integration addon.</p>'
                        renderFn = null
                        return
                    }
                    return ctx.apiGet('/server/database/item?namespace=cosmoace&key=slots')
                        .then(function (r2) { slotCfgs = r2.result.value || {} })
                        .catch(function () { slotCfgs = {} })
                        .then(function () {
                            refresh(ctx)
                            pollTimer = setInterval(lightPoll, 10000)
                        })
                }).catch(function () {
                    // klippy still starting — retry while the panel is on screen
                    body.innerHTML =
                        '<p class="cosmoace-note">Printer not ready — retrying…</p>'
                    if (el.isConnected) setTimeout(boot, 5000)
                })
            }
            boot()
        },
        unmount: function () {
            renderFn = null
            if (pollTimer) { clearInterval(pollTimer); pollTimer = null }
        },
    })
})()
