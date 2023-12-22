import requests
import time
import subprocess

REPO_COMMIT_SCRIPTS = {
    'MISP/MISP': './build_misp.sh',
    'MISP/misp-modules': './build_modules.sh'
}
REPO_TAG_SCRIPTS = {
    'mariadb/server': './build_mysql.sh',
    'redis/redis': './build_redis.sh'
}
CHECK_INTERVAL = 600  # in sec
LAST_SEEN_COMMITS = {}
LAST_SEEN_TAGS = {}

def get_latest_commit(repo):
    url = f'https://api.github.com/repos/{repo}/commits'
    response = requests.get(url)
    if response.status_code == 200:
        return response.json()[0]
    else:
        print(f"Failed to fetch commits for {repo}")
        return None

def check_for_new_commits(repo):
    global LAST_SEEN_COMMITS
    latest_commit = get_latest_commit(repo)
    if latest_commit and (latest_commit['sha'] != LAST_SEEN_COMMITS.get(repo)):
        print(f"New commit found in {repo}: {latest_commit['commit']['message']}")
        LAST_SEEN_COMMITS[repo] = latest_commit['sha']
        return True
    return False

def get_latest_tag(repo):
    url = f'https://api.github.com/repos/{repo}/tags'
    response = requests.get(url)
    if response.status_code == 200:
        return response.json()[0]
    else:
        print(f"Failed to fetch tags for {repo}")
        return None

def check_for_new_tag(repo):
    global LAST_SEEN_TAGS
    latest_tag = get_latest_tag(repo)
    if latest_tag and (latest_tag['commit']['sha'] != LAST_SEEN_TAGS.get(repo)):
        print(f"New tag found in {repo}: {latest_tag['commit']['sha']}")
        LAST_SEEN_TAGS[repo] = latest_tag['commit']['sha']
        return True
    return False

def run_build_script(repo, mode):
    script = None
    if mode == "commit":
        script = REPO_COMMIT_SCRIPTS.get(repo)
    elif mode == "tag":
        script = REPO_TAG_SCRIPTS.get(repo)

    if script:
        try:
            subprocess.run([script], check=True)
            print(f"Script executed successfully: {script}")
        except subprocess.CalledProcessError:
            print(f"An error occurred while running the script: {script}")
    else:
        print(f"No script defined for {repo} in {mode} mode.")

def main():
    global LAST_SEEN_COMMITS
    for repo in REPO_COMMIT_SCRIPTS.keys():
        LAST_SEEN_COMMITS[repo] = get_latest_commit(repo)['sha'] if get_latest_commit(repo) else None

    global LAST_SEEN_TAGS
    for repo in REPO_TAG_SCRIPTS.keys():
        LAST_SEEN_TAGS[repo] = get_latest_tag(repo)['commit']['sha'] if get_latest_tag(repo) else None

    print("Start looking for updates ...")
    while True:
        for repo in REPO_COMMIT_SCRIPTS.keys():
            if check_for_new_commits(repo):
                run_build_script(repo, "commit")
        for repo in REPO_TAG_SCRIPTS.keys():
            if check_for_new_tag(repo):
                run_build_script(repo, "tag")
        time.sleep(CHECK_INTERVAL)

if __name__ == '__main__':
    main()
