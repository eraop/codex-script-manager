from pathlib import Path
import sys


def main():
    if sys.platform != "win32":
        sys.exit("This Script Manager launcher requires native Windows.")
    if len(sys.argv) != 2 or not Path(sys.argv[1]).is_absolute():
        sys.exit("Pass the absolute path to an existing project folder.")

    sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
    import portable_bridge

    try:
        portable_bridge.open_project(sys.argv[1])
    except (OSError, portable_bridge.ConnectionError) as error:
        sys.exit(str(error))


if __name__ == "__main__":
    main()
