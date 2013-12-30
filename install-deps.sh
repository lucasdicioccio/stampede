

CHREPO="https://github.com/haskell-distributed"
DEPS="distributed-process\
        distributed-process-platform\
        network-transport\
        distributed-static\
        rank1dynamic\
        network-transport-tcp"

echo 'cloning deps into ./deps'
mkdir -p ./deps
cd ./deps
for project in $DEPS;
do
        repo="$CHREPO/$project.git"
        CMD="git clone $repo -b development"
        echo $CMD
        $CMD
done;
cd ..

cabal sandbox init
for project in $DEPS;
do
        repo="./deps/$project"
        CMD="cabal sandbox add-source $repo"
        echo $CMD
        $CMD
done;

cabal install --dependencies-only
