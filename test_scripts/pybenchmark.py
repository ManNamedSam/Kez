import time


class Zoo():
    aardvark = 1
    baboon = 1
    cat = 1
    donkey = 1
    elephant = 1
    fox = 1

    def getAardvark(self):
        return self.aardvark

    def getBaboon(self):
        return self.baboon

    def getCat(self):
        return self.cat

    def getDonkey(self):
        return self.donkey

    def getElephant(self):
        return self.elephant

    def getFox(self):
        return self.fox


zoo = Zoo()

sum = 0

start = time.time()

while sum < 100000000:
    sum = sum + zoo.getAardvark() + zoo.getBaboon() + zoo.getCat() + \
        zoo.getDonkey() + zoo.getElephant() + zoo.getFox()

print(
    time.time() - start
)

print(sum)
