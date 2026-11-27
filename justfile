image := "ghcr.io/justmiles/agent-sandbox:latest"

build:
    docker build . -t {{image}}

push: build
    docker push {{image}}

test: build
    test/smoke.sh {{image}}

run:
    docker run --rm -d --name agent-sandbox -v $PWD:/home/sandbox/workspace -p 127.0.0.1:8080:8080 {{image}}

run-shell:
    docker run --rm -it --name agent-sandbox -v $PWD:/home/sandbox/workspace --entrypoint bash {{image}}
