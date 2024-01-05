import json
import requests
import subprocess
from time import sleep
from typing import List, Dict, Any, Optional

class Repo:

    def __init__(self, id: str, mode: str, args: List[str]) -> None:
        self.id = id
        self.mode = mode
        self.args = args
        self.last_seen_update = None
        pass

    def _get_latest_update(self) -> Optional[Dict[str, Any]]:
        print(f"Fetching {self.mode} for {self.id}")
        url=f'https://api.github.com/repos/{self.id}/{self.mode}'
        response = requests.get(url)
        if response.status_code == 200:
            return response.json()[0]
        else:
            print(f"Failed to fetch {self.mode} for {self.id}")
            return None

    def _check_for_new_update(self) -> bool:
        latest_update = self._get_latest_update()
        if latest_update and (latest_update['sha'] != self.last_seen_update):
            print(f"New {self.mode} found in {self.id}")
            self.last_seen_update = latest_update['sha']
            return True
        return False

    def build(self) -> None:
        if self._check_for_new_update():
            try:
                cmd = ['/opt/misp_airgap/build/build.sh'] + self.args
                print (f"Running {cmd}")
                subprocess.run(cmd, check=True)
            except:
                print(f"Failed to run {cmd} for {self.id}")
        pass

def main():
    with open("/opt/misp_airgap/build/conf/tracker.json") as f:
        config = json.load(f)

    repos = []
    for repo in config["repos"]:
        repos.append(Repo(repo["id"], repo["mode"], repo["args"]))
    
    while True:
        for repo in repos:
            repo.build()
        sleep(config["check_interval"])
    

if __name__ == "__main__":
    main()
