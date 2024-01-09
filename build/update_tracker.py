import json
import requests
import subprocess
import re
from time import sleep
from typing import List, Optional

class Repo:
    """Base class for repository tracking and update checking."""

    def __init__(self, id: str, args: List[str]) -> None:
        self.id = id
        self.args = args
        self.last_seen_update = None

    def _check_for_new_update(self) -> bool:
        latest_update = self._get_latest_update()
        if latest_update and (latest_update != self.last_seen_update):
            print(f"New update found for {self.id}")
            self.last_seen_update = latest_update
            return True
        return False

    def _get_latest_update(self):
        raise NotImplementedError

    def build(self) -> None:
        if self._check_for_new_update():
            try:
                cmd = ['/opt/misp_airgap/build/build.sh'] + self.args
                print(f"Running {cmd}")
                subprocess.run(cmd, check=True)
            except Exception as e:
                print(f"Failed to run {cmd} for {self.id}: {e}")

class GitHub(Repo):
    """Class for tracking GitHub repositories."""

    def __init__(self, id: str, mode: str, args: List[str]) -> None:
        super().__init__(id, args)
        self.mode = mode

    def _get_latest_update(self) -> Optional[str]:
        print(f"Fetching {self.mode} for {self.id}")
        url=f'https://api.github.com/repos/{self.id}/{self.mode}'
        response = requests.get(url)
        if response.status_code == 200:
            return response.json()[0]['sha']
        else:
            print(f"Failed to fetch {self.mode} for {self.id}")
            return None

class APT(Repo):
    """Class for tracking APT packages."""

    def __init__(self, id: str, args: List[str]) -> None:
        super().__init__(id, args)

    def _get_latest_update(self) -> Optional[str]:
        try:
            cmd = ["apt-cache", "policy", self.id]
            print (f"Running {cmd}")
            output = subprocess.check_output(cmd).decode('utf-8')
            match = re.search(r'Candidate: (\S+)', output)
            if match:
                return match.group(1)
            else:
                return None
        except:
            return None

def main():
    with open("/opt/misp_airgap/build/conf/tracker.json") as f:
        config = json.load(f)

    repos = []
    for repo in config["github"]:
        repos.append(GitHub(repo["id"], repo["mode"], repo["args"]))

    aptpkg = []
    for package in config["apt"]:
        aptpkg.append(APT(package["id"], package["args"]))
    
    while True:
        for repo in repos:
            repo.build()
        for package in aptpkg:
            package.build()
        sleep(config["check_interval"])
    
if __name__ == "__main__":
    main()
