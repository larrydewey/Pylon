#!/usr/bin/env python3
"""A TCP proxy that delays each direction by a fixed time (no bandwidth
limit): a long link on the loopback interface.

    delay_proxy.py LISTEN_PORT TARGET_PORT ONE_WAY_MS
"""
import asyncio
import sys
import time

LPORT, DPORT, DELAY = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3]) / 1000


async def pump(r, w):
    q = asyncio.Queue()

    async def rd():
        while True:
            b = await r.read(1 << 20)
            await q.put((time.monotonic() + DELAY, b))
            if not b:
                return

    async def wr():
        while True:
            t, b = await q.get()
            d = t - time.monotonic()
            if d > 0:
                await asyncio.sleep(d)
            if not b:
                w.close()
                return
            w.write(b)
            await w.drain()

    await asyncio.gather(rd(), wr())


async def conn(cr, cw):
    sr, sw = await asyncio.open_connection('127.0.0.1', DPORT)
    await asyncio.gather(pump(cr, sw), pump(sr, cw), return_exceptions=True)


async def main():
    s = await asyncio.start_server(conn, '127.0.0.1', LPORT)
    async with s:
        await s.serve_forever()

asyncio.run(main())
