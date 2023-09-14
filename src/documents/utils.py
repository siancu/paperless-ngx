import shutil
from logging import Logger
from os import utime
from pathlib import Path
from subprocess import run
from typing import Optional
from typing import Union


def _coerce_to_path(
    source: Union[Path, str],
    dest: Union[Path, str],
) -> tuple[Path, Path]:
    return Path(source).resolve(), Path(dest).resolve()


def copy_basic_file_stats(source: Union[Path, str], dest: Union[Path, str]) -> None:
    """
    Copies only the m_time and a_time attributes from source to destination.
    Both are expected to exist.

    The extended attribute copy does weird things with SELinux and files
    copied from temporary directories and copystat doesn't allow disabling
    these copies
    """
    source, dest = _coerce_to_path(source, dest)
    src_stat = source.stat()
    utime(dest, ns=(src_stat.st_atime_ns, src_stat.st_mtime_ns))


def copy_file_with_basic_stats(
    source: Union[Path, str],
    dest: Union[Path, str],
) -> None:
    """
    A sort of simpler copy2 that doesn't copy extended file attributes,
    only the access time and modified times from source to dest.

    The extended attribute copy does weird things with SELinux and files
    copied from temporary directories.
    """
    source, dest = _coerce_to_path(source, dest)

    shutil.copy(source, dest)
    copy_basic_file_stats(source, dest)


def run_process_with_capture(
    args: list[str],
    logger: Logger,
    *,
    env: Optional[dict[str, str]] = None,
    check_return=False,
    log_return=True,
    log_stdout=True,
    log_stderr=True,
):
    """
    Utility to run a given command with the environment and optionally:
    - log stdout and stderr
    - log return code
    - check the return code and raise CalledProcess if non-zero
    """

    def parse_outputs(output: bytes) -> list[str]:
        return output.decode("utf8", errors="ignore").strip().splitlines()

    proc = run(args, env=env, capture_output=True)

    if log_return and logger is not None:
        # Log what the script exited as
        logger.debug(
            f"{proc.args[0]} exited {proc.returncode}",
        )

    if log_stderr and logger is not None and len(proc.stderr):
        logger.warning("stderr:")
        for line in parse_outputs(proc.stderr):
            logger.warning(line)

    if log_stdout and logger is not None and len(proc.stdout):
        logger.debug("stdout:")
        for line in parse_outputs(proc.stdout):
            logger.debug(line)

    if check_return:
        proc.check_returncode()
