"""Overload protection: a few model slots per pod, a short line, then "busy" at once."""
import asyncio

from app.main import ModelGate


def test_slots_then_line_then_refuse():
    async def run():
        g = ModelGate(slots=1, queue=1, wait=5)
        assert await g.acquire()                 # takes the only slot
        assert g.must_wait() and not g.full()
        waiter = asyncio.create_task(g.acquire())  # waits in line
        await asyncio.sleep(0.01)
        assert g.waiting == 1 and g.full()
        assert not await g.acquire()             # line full: refused at once
        await g.release()                        # slot frees: the one in line gets it
        assert await waiter
        assert g.active == 1 and g.waiting == 0
        await g.release()
        assert g.active == 0
    asyncio.run(run())


def test_waiting_too_long_gives_up_and_leaves_the_line():
    async def run():
        g = ModelGate(slots=1, queue=3, wait=0.05)
        assert await g.acquire()
        assert not await g.acquire()             # timed out in line
        assert g.waiting == 0 and g.active == 1
    asyncio.run(run())


def test_leaving_the_line_early_frees_the_place():
    async def run():
        g = ModelGate(slots=1, queue=1, wait=5)
        assert await g.acquire()
        waiter = asyncio.create_task(g.acquire())
        await asyncio.sleep(0.01)
        waiter.cancel()                          # the browser went away while waiting
        await asyncio.gather(waiter, return_exceptions=True)
        assert g.waiting == 0 and not g.full()
    asyncio.run(run())
