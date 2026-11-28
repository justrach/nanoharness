#!/usr/bin/env python3
"""Synthetic regression tests; no compiler, shared build lock, or user data."""

import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
import unittest


WRAPPER = Path(__file__).resolve().with_name("heavy-build.sh")
# The owner cannot hang the suite if a regression prevents its release.
HOLD_COMMAND = """
from pathlib import Path
import sys, time
started, release = map(Path, sys.argv[1:3])
started.touch()
deadline = time.monotonic() + 10
while not release.exists():
    if time.monotonic() > deadline:
        sys.exit(98)
    time.sleep(0.01)
"""


# Fake builds: record a label, or record a start and an end around a short hold.
APPEND = 'printf "%s\\n" "$1" >> "$2"'
APPEND_HOLD = 'printf "start %s\\n" "$1" >> "$2"; sleep "$3"; printf "end %s\\n" "$1" >> "$2"'


def lines(path):
    return path.read_text().split("\n")[:-1] if path.exists() else []


class HeavyBuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="heavy-build-test-")
        self.root = Path(self.temp.name)
        self.lock = self.root / "slot.lock"
        self.wait_dir = self.root / "wait"
        self.wait_dir.mkdir()
        self.processes = []
        self.env = os.environ.copy()
        self.env.update(
            HARNESS_HEAVY_BUILD_LOCK=str(self.lock),
            HARNESS_BUILD_WAIT_DIR=str(self.wait_dir),
            HARNESS_HEAVY_BUILD_POLL_INTERVAL="0.03",
        )

    def tearDown(self):
        # Kill only the synthetic process groups started by this test.
        for process in self.processes:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=3)
        self.temp.cleanup()

    def start(self, code, *args, with_wait_dir=True, env=None):
        env = (env or self.env).copy()
        if not with_wait_dir:
            env.pop("HARNESS_BUILD_WAIT_DIR", None)
        return self.start_argv([sys.executable, "-c", code, *map(str, args)], env)

    def start_argv(self, argv, env=None):
        process = subprocess.Popen(
            ["bash", str(WRAPPER), *map(str, argv)],
            env=env or self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        self.processes.append(process)
        return process

    def wait_for(self, predicate, message):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.01)
        self.fail(message)

    def finish(self, process, expected=0):
        stdout, stderr = process.communicate(timeout=3)
        self.assertEqual(process.returncode, expected, (stdout, stderr))
        self.assertEqual((stdout, stderr), (b"", b""), "wrapper must stay quiet")

    def hold_slot(self, name="owner", env=None, lock=None):
        started = self.root / f"{name}-started"
        release = self.root / f"{name}-release"
        owner = self.start(HOLD_COMMAND, started, release, env=env)
        self.wait_for(started.exists, "synthetic owner never acquired the slot")
        if lock is None and env is None:
            lock = self.lock
        if lock is not None:
            self.assertEqual((lock / "pid").read_text().strip(), str(owner.pid))
        return owner, release

    def lane_env(self, **overrides):
        """An environment without an explicit lock path, so lanes resolve under the test's TMPDIR."""
        env = self.env.copy()
        env.pop("HARNESS_HEAVY_BUILD_LOCK", None)
        env["TMPDIR"] = str(self.root)
        env.update(overrides)
        return env

    def append(self, label, log, env=None, hold=None):
        """A fake build that records when it runs (and, given hold, when it ends)."""
        if hold is None:
            return self.start_argv(["/bin/sh", "-c", APPEND, "sh", label, log], env)
        return self.start_argv(["/bin/sh", "-c", APPEND_HOLD, "sh", label, log, hold], env)

    def queue_in_order(self, labels, log, env=None):
        """Start one waiter per label, each only after the previous one is queued."""
        waiters = []
        for label in labels:
            waiter = self.append(label, log, env)
            self.wait_marker(waiter)
            waiters.append(waiter)
        return waiters

    def status(self, *args, env=None):
        result = subprocess.run(
            ["bash", str(WRAPPER), "--status", *args],
            env=env or self.env,
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertEqual((result.returncode, result.stderr), (0, ""), result.stdout)
        return result.stdout

    def status_pids(self, text, kind):
        return [int(m) for m in re.findall(rf"^  {kind}\b.*?\bpid (\d+)", text, re.M)]

    def wait_marker(self, process):
        marker = self.wait_dir / str(process.pid)
        self.wait_for(marker.exists, "contended wrapper did not publish a wait marker")
        self.wait_for(lambda: bool(marker.read_text().strip()), "empty wait marker")
        return marker

    def test_contention_marker_is_stable_and_acquisition_clears_it(self):
        owner, owner_release = self.hold_slot()
        waiter_started = self.root / "waiter-started"
        waiter_release = self.root / "waiter-release"
        before = int(time.time())
        waiter = self.start(HOLD_COMMAND, waiter_started, waiter_release)
        marker = self.wait_marker(waiter)
        timestamp = marker.read_text().strip()
        self.assertTrue(timestamp.isdecimal())
        self.assertLessEqual(before, int(timestamp))
        self.assertLessEqual(int(timestamp), int(time.time()))
        self.assertFalse(waiter_started.exists(), "two commands ran at once")
        # Cross a Unix-second boundary and many polling retries.
        time.sleep(1.1)
        self.assertEqual(marker.read_text().strip(), timestamp)
        self.assertEqual(sorted(p.name for p in self.wait_dir.iterdir()), [str(waiter.pid)])
        owner_release.touch()
        self.finish(owner)
        self.wait_for(waiter_started.exists, "queued command never acquired the slot")
        self.assertFalse(marker.exists(), "marker survived lock acquisition")
        self.assertEqual((self.lock / "pid").read_text().strip(), str(waiter.pid))
        waiter_release.touch()
        self.finish(waiter)
        self.assertFalse(self.lock.exists())

    def check_queued_cancellation(self, sig):
        owner, release = self.hold_slot()
        waiter = self.start("raise SystemExit(97)")
        marker = self.wait_marker(waiter)
        waiter.send_signal(sig)
        self.finish(waiter, 128 + sig)
        self.assertFalse(marker.exists(), "cancelled wait marker survived")
        self.assertIsNone(owner.poll())
        self.assertEqual((self.lock / "pid").read_text().strip(), str(owner.pid))
        release.touch()
        self.finish(owner)
        self.assertFalse(self.lock.exists())

    def test_queued_term_keeps_owners_lock(self):
        self.check_queued_cancellation(signal.SIGTERM)

    def test_queued_int_keeps_owners_lock(self):
        self.check_queued_cancellation(signal.SIGINT)

    def test_command_failure_releases_slot_and_preserves_status(self):
        failed = self.start("raise SystemExit(23)")
        self.finish(failed, 23)
        self.assertFalse(self.lock.exists())
        self.assertEqual(list(self.wait_dir.iterdir()), [])
        following = self.start("pass")
        self.finish(following)
        self.assertFalse(self.lock.exists())

    def test_uncontended_command_never_has_marker(self):
        started = self.root / "started"
        release = self.root / "release"
        process = self.start(HOLD_COMMAND, started, release)
        self.wait_for(started.exists, "uncontended command did not start")
        self.assertEqual(list(self.wait_dir.iterdir()), [])
        release.touch()
        self.finish(process)
        self.assertEqual(list(self.wait_dir.iterdir()), [])
        self.assertFalse(self.lock.exists())

    def test_retired_wait_directory_is_not_recreated(self):
        owner, release = self.hold_slot()
        self.wait_dir.rmdir()
        waiter = self.start("pass")
        time.sleep(0.15)
        self.assertFalse(self.wait_dir.exists(), "a retired run's private directory was recreated")
        self.assertIsNone(waiter.poll())
        release.touch()
        self.finish(owner)
        self.finish(waiter)

    def test_no_wait_directory_does_not_publish_marker(self):
        owner, release = self.hold_slot()
        started = self.root / "without-marker-started"
        waiter = self.start("from pathlib import Path; import sys; Path(sys.argv[1]).touch()", started,
                            with_wait_dir=False)
        time.sleep(0.15)
        self.assertIsNone(waiter.poll())
        self.assertFalse(started.exists())
        self.assertEqual(list(self.wait_dir.iterdir()), [])
        release.touch()
        self.finish(owner)
        # The original wrapper polls every five seconds; this test also runs on it.
        stdout, stderr = waiter.communicate(timeout=7)
        self.assertEqual((waiter.returncode, stdout, stderr), (0, b"", b""))
        self.assertTrue(started.exists())
        self.assertEqual(list(self.wait_dir.iterdir()), [])
        self.assertFalse(self.lock.exists())

    def test_nested_wrapper_inside_owner_runs_without_deadlock(self):
        nested_done = self.root / "nested-done"
        outer = self.start(
            "import subprocess, sys; "
            "subprocess.run(['bash', sys.argv[1], sys.executable, '-c', "
            "'from pathlib import Path; import sys; Path(sys.argv[1]).touch()', sys.argv[2]], check=True)",
            WRAPPER,
            nested_done,
        )
        self.finish(outer)
        self.assertTrue(nested_done.exists())
        self.assertEqual(list(self.wait_dir.iterdir()), [])
        self.assertFalse(self.lock.exists())

    # First come, first served.

    def test_waiters_run_in_arrival_order(self):
        for round_ in range(5):
            log = self.root / f"order-{round_}.log"
            owner, release = self.hold_slot(f"owner-{round_}")
            labels = [f"job-{i}" for i in range(5)]
            waiters = self.queue_in_order(labels, log)
            release.touch()
            self.finish(owner)
            for waiter in waiters:
                self.finish(waiter)
            self.assertEqual(lines(log), labels, f"round {round_}")
            self.assertFalse(self.lock.exists())

    def test_steady_stream_never_overtakes_an_earlier_waiter(self):
        log = self.root / "stream.log"
        owner, release = self.hold_slot()
        # The earliest waiter polls slowly, so any arrival that can jump the
        # queue gets several chances to do so.
        slow = self.env.copy()
        slow["HARNESS_HEAVY_BUILD_POLL_INTERVAL"] = "0.3"
        early = self.append("early", log, slow)
        self.wait_marker(early)
        queued = [f"queued-{i}" for i in range(4)]
        waiters = [early, *self.queue_in_order(queued, log)]
        release.touch()
        self.finish(owner)
        late = []
        deadline = time.monotonic() + 0.5
        while time.monotonic() < deadline:
            label = f"late-{len(late)}"
            late.append(label)
            waiters.append(self.append(label, log))
            time.sleep(0.025)
        for waiter in waiters:
            self.finish(waiter)
        ran = lines(log)
        self.assertEqual(ran[:5], ["early", *queued])
        self.assertEqual(sorted(ran), sorted(["early", *queued, *late]))

    def test_dead_waiter_in_the_middle_of_the_queue_is_skipped(self):
        log = self.root / "dead.log"
        owner, release = self.hold_slot()
        waiters = self.queue_in_order([f"job-{i}" for i in range(5)], log)
        dead = waiters.pop(2)
        os.killpg(dead.pid, signal.SIGKILL)
        dead.wait(timeout=3)
        status = self.status()
        self.assertEqual(self.status_pids(status, "holding"), [owner.pid])
        self.assertEqual(self.status_pids(status, "queued"), [w.pid for w in waiters])
        release.touch()
        self.finish(owner)
        for waiter in waiters:
            self.finish(waiter)
        self.assertEqual(lines(log), ["job-0", "job-1", "job-3", "job-4"])

    def check_cancelled_waiter_leaves_the_queue(self, sig):
        log = self.root / "cancel.log"
        owner, release = self.hold_slot()
        first, cancelled, last = self.queue_in_order(["first", "cancelled", "last"], log)
        marker = self.wait_dir / str(cancelled.pid)
        cancelled.send_signal(sig)
        self.finish(cancelled, 128 + sig)
        self.assertFalse(marker.exists(), "cancelled wait marker survived")
        status = self.status()
        self.assertEqual(self.status_pids(status, "holding"), [owner.pid])
        self.assertEqual(self.status_pids(status, "queued"), [first.pid, last.pid])
        self.assertEqual((self.lock / "pid").read_text().strip(), str(owner.pid))
        self.assertIsNone(owner.poll())
        release.touch()
        self.finish(owner)
        self.finish(first)
        self.finish(last)
        self.assertEqual(lines(log), ["first", "last"])

    def test_cancelled_waiter_term_leaves_no_ticket(self):
        self.check_cancelled_waiter_leaves_the_queue(signal.SIGTERM)

    def test_cancelled_waiter_int_leaves_no_ticket(self):
        self.check_cancelled_waiter_leaves_the_queue(signal.SIGINT)

    def test_stale_holder_frees_its_slot_for_the_next_in_line(self):
        for round_ in range(2):
            log = self.root / f"stale-{round_}.log"
            owner, _ = self.hold_slot(f"owner-{round_}")
            labels = [f"job-{i}" for i in range(5)]
            waiters = self.queue_in_order(labels, log)
            # The holder dies without releasing anything.
            os.killpg(owner.pid, signal.SIGKILL)
            owner.wait(timeout=3)
            for waiter in waiters:
                self.finish(waiter)
            self.assertEqual(lines(log), labels, f"round {round_}")
            self.assertFalse(self.lock.exists())

    # Lanes and slots.

    def test_lanes_run_concurrently_and_queue_independently(self):
        log = self.root / "lanes.log"
        alpha = self.lane_env(HARNESS_HEAVY_BUILD_LANE="alpha")
        beta = self.lane_env(HARNESS_HEAVY_BUILD_LANE="beta")
        alpha_lock = self.root / "harness-heavy-build.alpha.lock"
        alpha_owner, alpha_release = self.hold_slot("alpha", env=alpha, lock=alpha_lock)
        alpha_waiter = self.append("alpha-waiter", log, alpha)
        self.wait_marker(alpha_waiter)
        # Another lane runs while this one is held and has a queue.
        beta_lock = self.root / "harness-heavy-build.beta.lock"
        beta_owner, beta_release = self.hold_slot("beta", env=beta, lock=beta_lock)
        self.assertNotIn(str(beta_owner.pid), [p.name for p in self.wait_dir.iterdir()])
        beta_waiter = self.append("beta-waiter", log, beta)
        self.wait_marker(beta_waiter)
        beta_release.touch()
        self.finish(beta_owner)
        self.finish(beta_waiter)
        self.assertEqual(lines(log), ["beta-waiter"])
        self.assertIsNone(alpha_waiter.poll(), "alpha's waiter ran while alpha was held")
        alpha_release.touch()
        self.finish(alpha_owner)
        self.finish(alpha_waiter)
        self.assertEqual(lines(log), ["beta-waiter", "alpha-waiter"])
        self.assertFalse(alpha_lock.exists())
        self.assertFalse(beta_lock.exists())

    def test_slots_let_n_jobs_run_and_the_next_waits(self):
        pool = self.lane_env(HARNESS_HEAVY_BUILD_LANE="pool", HARNESS_HEAVY_BUILD_SLOTS="2")
        first, first_release = self.hold_slot("first", env=pool)
        second, second_release = self.hold_slot("second", env=pool)
        third_started = self.root / "third-started"
        third_release = self.root / "third-release"
        third = self.start(HOLD_COMMAND, third_started, third_release, env=pool)
        self.wait_marker(third)
        time.sleep(0.15)
        self.assertFalse(third_started.exists(), "a third job ran in a two-slot lane")
        first_release.touch()
        self.finish(first)
        self.wait_for(third_started.exists, "the waiter never took the freed slot")
        second_release.touch()
        third_release.touch()
        self.finish(second)
        self.finish(third)

    def test_slots_never_exceed_the_limit(self):
        log = self.root / "slots.log"
        pool = self.lane_env(HARNESS_HEAVY_BUILD_LANE="pool", HARNESS_HEAVY_BUILD_SLOTS="2")
        jobs = [self.append(f"job-{i}", log, pool, hold="0.15") for i in range(6)]
        for job in jobs:
            self.finish(job)
        running = peak = 0
        for line in lines(log):
            running += 1 if line.startswith("start ") else -1
            peak = max(peak, running)
        self.assertEqual(len(lines(log)), 12)
        self.assertEqual(peak, 2)

    # Compatibility with existing callers.

    def test_default_invocation_is_one_shared_lane(self):
        default = self.lane_env()
        lock = self.root / "harness-heavy-build.lock"
        owner, release = self.hold_slot(env=default, lock=lock)
        log = self.root / "default.log"
        waiter = self.append("waiter", log, default)
        self.wait_marker(waiter)
        time.sleep(0.1)
        self.assertEqual(lines(log), [])
        release.touch()
        self.finish(owner)
        self.finish(waiter)
        self.assertEqual(lines(log), ["waiter"])
        self.assertFalse(lock.exists())

    def test_reentrancy_is_per_lane(self):
        log = self.root / "nested.log"
        beta = self.lane_env(HARNESS_HEAVY_BUILD_LANE="beta")
        beta_owner, beta_release = self.hold_slot("beta", env=beta, lock=self.root / "harness-heavy-build.beta.lock")
        ready = self.root / "outer-ready"
        outer = self.start(
            "import os, subprocess, sys; from pathlib import Path\n"
            "wrapper, log, ready = sys.argv[1:4]\n"
            "nested = ['bash', wrapper, '/bin/sh', '-c', sys.argv[4], 'sh']\n"
            "subprocess.run(nested + ['same-lane', log], check=True)\n"
            "Path(ready).touch()\n"
            "subprocess.run(nested + ['other-lane', log], check=True, env=dict(os.environ, HARNESS_HEAVY_BUILD_LANE='beta'))\n",
            WRAPPER, log, ready, APPEND,
            env=self.lane_env(HARNESS_HEAVY_BUILD_LANE="alpha"),
        )
        self.wait_for(ready.exists, "a nested call in the owner's lane did not run at once")
        self.assertEqual(lines(log), ["same-lane"])
        # The owner of alpha holds nothing in beta, so it queues there.
        self.wait_for(lambda: len(list(self.wait_dir.iterdir())) == 1, "nested call in another lane did not queue")
        time.sleep(0.1)
        self.assertEqual(lines(log), ["same-lane"])
        beta_release.touch()
        self.finish(beta_owner)
        self.finish(outer)
        self.assertEqual(lines(log), ["same-lane", "other-lane"])

    def test_nested_lanes_back_into_a_held_lane_do_not_deadlock(self):
        # alpha -> beta -> alpha: the innermost call is re-entrant in alpha.
        log = self.root / "nested.log"
        nest = self.root / "nest.sh"
        nest.write_text(
            'wrapper=$1 log=$2; shift 2\n'
            'if [ $# -eq 0 ]; then printf "inner\\n" >> "$log"; exit; fi\n'
            'lane=$1; shift\n'
            'HARNESS_HEAVY_BUILD_LANE=$lane exec bash "$wrapper" /bin/sh "$0" "$wrapper" "$log" "$@"\n'
        )
        outer = self.start_argv(["/bin/sh", nest, WRAPPER, log, "beta", "alpha"],
                                self.lane_env(HARNESS_HEAVY_BUILD_LANE="alpha"))
        self.finish(outer)
        self.assertEqual(lines(log), ["inner"])

    # Status.

    def test_status_of_an_empty_lane(self):
        self.assertEqual(self.status(), f"lane {self.lock}: idle\n")
        self.assertFalse(self.lock.exists(), "status took the slot")
        env = self.lane_env()
        self.assertEqual(self.status("zig", env=env), f"lane zig: idle\n")
        self.assertEqual(self.status(env=env), f"lane default: idle\n")
        self.assertEqual(list(self.root.glob("harness-heavy-build*")), [])

    def test_status_of_a_held_lane_with_a_queue(self):
        owner, release = self.hold_slot()
        status = self.status()
        self.assertTrue(status.startswith(f"lane {self.lock}: 1 holding, 0 queued\n"), status)
        holding = status.splitlines()[1]
        self.assertRegex(holding, rf"^  holding pid {owner.pid} for \d+s: \S*python\S* -c\s+from pathlib import Path ")
        log = self.root / "status.log"
        waiters = self.queue_in_order(["first", "second"], log)
        status = self.status()
        self.assertTrue(status.startswith(f"lane {self.lock}: 1 holding, 2 queued\n"), status)
        self.assertEqual(self.status_pids(status, "holding"), [owner.pid])
        self.assertEqual(self.status_pids(status, "queued"), [w.pid for w in waiters])
        self.assertRegex(status.splitlines()[2], rf"^  queued #1 pid {waiters[0].pid} for \d+s: /bin/sh -c ")
        self.assertRegex(status.splitlines()[3], rf"^  queued #2 pid {waiters[1].pid} for \d+s: /bin/sh -c ")
        # Reading status neither takes a slot nor disturbs the queue.
        self.assertEqual((self.lock / "pid").read_text().strip(), str(owner.pid))
        release.touch()
        self.finish(owner)
        for waiter in waiters:
            self.finish(waiter)
        self.assertEqual(lines(log), ["first", "second"])
        self.assertEqual(self.status(), f"lane {self.lock}: idle\n")

    def test_status_lists_every_lane(self):
        alpha = self.lane_env(HARNESS_HEAVY_BUILD_LANE="alpha")
        owner, release = self.hold_slot("alpha", env=alpha, lock=self.root / "harness-heavy-build.alpha.lock")
        status = self.status(env=self.lane_env()).splitlines()
        self.assertEqual(status[0], "lane default: idle")
        self.assertIn("lane alpha: 1 holding, 0 queued", status)
        self.assertIn(f"  holding pid {owner.pid}", "\n".join(status))
        release.touch()
        self.finish(owner)

    # Long holds are reported, never killed.

    def test_long_hold_is_reported_once_per_interval_on_stderr(self):
        owner_started = self.root / "owner-started"
        owner_release = self.root / "owner-release"
        owner = self.start(HOLD_COMMAND, owner_started, owner_release, "x" * 400)
        self.wait_for(owner_started.exists, "synthetic owner never acquired the slot")
        warn = self.env.copy()
        warn["HARNESS_HEAVY_BUILD_WARN_AFTER"] = "1"
        waiter = self.append("waiter", self.root / "long.log", warn)
        self.wait_marker(waiter)
        time.sleep(3.4)
        self.assertIsNone(owner.poll(), "a long hold must not be killed")
        owner_release.touch()
        self.finish(owner)
        stdout, stderr = waiter.communicate(timeout=3)
        self.assertEqual((waiter.returncode, stdout), (0, b""))
        notices = stderr.decode().splitlines()
        # Polls every 0.03 s, so once per poll would be about a hundred lines.
        self.assertGreaterEqual(len(notices), 2, notices)
        self.assertLessEqual(len(notices), 4, notices)
        for notice in notices:
            self.assertRegex(notice, rf"^heavy-build: pid {owner.pid} has held a slot in lane {re.escape(str(self.lock))} for \d+s: \S*python")
            self.assertLessEqual(len(notice), 300, "the command line is truncated")

    # The queue is bookkeeping: if it cannot be set up, the build still runs,
    # one at a time on slot 1, as before the queue existed.

    def queue_is_a_file(self):
        queue = Path(f"{self.lock}.queue")
        queue.write_text("not a directory\n")
        return queue

    def read_only_queue(self):
        if os.geteuid() == 0:
            self.skipTest("root ignores directory permissions")
        queue = Path(f"{self.lock}.queue")
        queue.mkdir(exist_ok=True)
        queue.chmod(0o555)
        # Runs after tearDown, which removes the (empty) directory.
        self.addCleanup(lambda: queue.is_dir() and queue.chmod(0o755))
        return queue

    def finish_without_queue(self, process, expected=0):
        """The command's exit code, no stdout, and exactly one warning naming the queue."""
        stdout, stderr = process.communicate(timeout=5)
        self.assertEqual((process.returncode, stdout), (expected, b""), stderr)
        queue = re.escape(f"{self.lock}.queue")
        self.assertRegex(stderr.decode(), rf"\Aheavy-build: queue unavailable at {queue}; running this build without it\n\Z")

    def check_runs_without_queue(self):
        started = self.root / "started"
        process = self.start(
            "from pathlib import Path; import sys; Path(sys.argv[1]).touch(); raise SystemExit(23)", started)
        self.finish_without_queue(process, 23)
        self.assertTrue(started.exists(), "the command never ran")
        self.assertFalse(self.lock.exists(), "the lock was not released")
        self.assertEqual(list(self.wait_dir.iterdir()), [])

    def test_queue_path_that_is_a_file_runs_the_build_without_the_queue(self):
        queue = self.queue_is_a_file()
        self.check_runs_without_queue()
        self.assertEqual(queue.read_text(), "not a directory\n")

    def test_queue_that_cannot_be_written_runs_the_build_without_the_queue(self):
        queue = self.read_only_queue()
        self.check_runs_without_queue()
        self.assertEqual(list(queue.iterdir()), [])

    def test_more_slots_without_a_queue_use_slot_one_only(self):
        self.queue_is_a_file()
        log = self.root / "slots.log"
        env = self.env.copy()
        env["HARNESS_HEAVY_BUILD_SLOTS"] = "3"
        jobs = [self.append(f"job-{i}", log, env, hold="0.1") for i in range(4)]
        for job in jobs:
            self.finish_without_queue(job)
        running = peak = 0
        for line in lines(log):
            running += 1 if line.startswith("start ") else -1
            peak = max(peak, running)
        self.assertEqual(len(lines(log)), 8)
        self.assertEqual(peak, 1, lines(log))
        self.assertEqual(list(self.root.glob("slot.lock.slot*")), [])
        self.assertFalse(self.lock.exists())

    def test_callers_without_a_queue_exclude_each_other(self):
        self.queue_is_a_file()
        log = self.root / "fallback.log"
        jobs = [self.append(f"job-{i}", log, hold="0.1") for i in range(4)]
        for job in jobs:
            self.finish_without_queue(job)
        running = peak = 0
        for line in lines(log):
            running += 1 if line.startswith("start ") else -1
            peak = max(peak, running)
        self.assertEqual(len(lines(log)), 8)
        self.assertEqual(peak, 1, lines(log))
        self.assertFalse(self.lock.exists())

    def test_caller_without_a_queue_waits_for_a_queued_holder(self):
        owner, release = self.hold_slot()
        self.read_only_queue()
        started = self.root / "fallback-started"
        waiter = self.start("from pathlib import Path; import sys; Path(sys.argv[1]).touch()", started)
        self.wait_marker(waiter)
        time.sleep(0.15)
        self.assertFalse(started.exists(), "ran while a queued holder had slot 1")
        self.assertEqual((self.lock / "pid").read_text().strip(), str(owner.pid))
        release.touch()
        self.finish(owner)
        self.finish_without_queue(waiter)
        self.assertTrue(started.exists())
        self.assertFalse(self.lock.exists())

    def test_queued_caller_waits_for_a_holder_without_a_queue(self):
        queue = self.read_only_queue()
        started = self.root / "owner-started"
        release = self.root / "owner-release"
        owner = self.start(HOLD_COMMAND, started, release)
        self.wait_for(started.exists, "the caller without a queue never took slot 1")
        self.assertEqual((self.lock / "pid").read_text().strip(), str(owner.pid))
        queue.chmod(0o755)
        log = self.root / "queued.log"
        waiter = self.append("queued", log)
        self.wait_marker(waiter)
        time.sleep(0.15)
        self.assertEqual(lines(log), [], "ran while a holder without a queue had slot 1")
        release.touch()
        self.finish_without_queue(owner)
        self.finish(waiter)
        self.assertEqual(lines(log), ["queued"])
        self.assertFalse(self.lock.exists())

    def test_cancelled_caller_without_a_queue_keeps_owners_lock(self):
        owner, release = self.hold_slot()
        self.read_only_queue()
        waiter = self.start("raise SystemExit(97)")
        marker = self.wait_marker(waiter)
        waiter.send_signal(signal.SIGTERM)
        stdout, stderr = waiter.communicate(timeout=3)
        self.assertEqual((waiter.returncode, stdout), (143, b""), stderr)
        self.assertFalse(marker.exists(), "cancelled wait marker survived")
        self.assertIsNone(owner.poll())
        self.assertEqual((self.lock / "pid").read_text().strip(), str(owner.pid))
        release.touch()
        self.finish(owner)
        self.assertFalse(self.lock.exists())

    def test_stale_lock_is_cleared_without_a_queue(self):
        self.queue_is_a_file()
        dead = subprocess.Popen([sys.executable, "-c", "pass"])
        dead.wait(timeout=3)
        self.lock.mkdir()
        (self.lock / "pid").write_text(f"{dead.pid}\n")
        self.check_runs_without_queue()

    def test_status_reports_the_holder_when_the_queue_is_unusable(self):
        queue = self.queue_is_a_file()
        owner, release = self.hold_slot()
        status = self.status()
        self.assertTrue(status.startswith(f"lane {self.lock}: 1 holding, 0 queued\n"), status)
        self.assertEqual(self.status_pids(status, "holding"), [owner.pid])
        self.assertIn(f"  queue unavailable at {queue}; builds run without it\n", status)
        release.touch()
        self.finish_without_queue(owner)
        self.assertEqual(self.status(), f"lane {self.lock}: idle\n  queue unavailable at {queue}; builds run without it\n")
        queue.unlink()
        self.read_only_queue()
        self.assertIn("queue unavailable at", self.status())

    def test_status_reports_a_holder_that_never_had_a_queue(self):
        # As when a sandbox denies creating the queue: the lock exists, the queue never did.
        self.lock.mkdir()
        (self.lock / "pid").write_text(f"{os.getpid()}\n")
        status = self.status()
        self.assertEqual(self.status_pids(status, "holding"), [os.getpid()])
        self.assertIn(f"  queue unavailable at {self.lock}.queue; builds run without it\n", status)


if __name__ == "__main__":
    unittest.main(verbosity=2)
