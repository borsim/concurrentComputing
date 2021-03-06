/*
 * fourAnts.xc
 *
 *  Created on: 6 Oct 2017
 *      Author: Rudy, Miki
 */

#include <platform.h>
#include <stdio.h>

struct ant {
    char x;
    char y;
    char food;
};
typedef struct ant ant;

const char field[3][4] = {{10,0,1,7},{2,10,0,3},{6,8,7,6}};

void queenServer (chanend a0, chanend a1) {
    int serving = 10;
    char a1food;
    char a0food;
    char totalFood = 0;
    while (serving > 0) {
      printf("Total food collected: &c", totalFood);
      a1 :> a1food;
      a0 :> a0food;
      if (a0food > a1food) {
          totalFood += a0food;
          // 1 to keep moving, 0 to harvest
          a1 <: 1;
          a0 <: 0;
      } else {
          totalFood += a1food;
          a1 <: 0;
          a0 <: 1;
      }
      serving--;
    }

}
void antClient (const char field[3][4], ant *thisAnt, chanend c) {
    int iterations = 10;
    while (iterations > 0) {
        char x = thisAnt -> x;
        char y = thisAnt -> x;
        char food = thisAnt -> food;
        char instruction = 0;
        //report
        c <: field[x][y];
        //receive instruction
        c :> instruction;
        //perform approporiate action
        if (instruction == 0) {
            food += field[x][y];
        } else {
            for (int i = 0; i < 2; i ++){
                char east  = field[(x+1) % 3][(y) % 4];
                char south = field[(x) % 3][(y+1) % 4];
                if (east > south) {
                   x = (x + 1) % 3;
                } else {
                   y = (y + 1) % 4;
                }
            }
        }
        thisAnt -> x = x;
        thisAnt -> x = y;
        thisAnt -> food = food;
        iterations--;
    }
}



int main() {
    ant ant0, ant1, queen;
    ant0.x = 1;
    ant0.y = 0;
    ant0.food = 0;
    ant1.x = 0;
    ant1.y = 1;
    ant1.food = 0;
    queen.x = 1;
    queen.y = 1;
    queen.food = 0;

    chan a1;
    chan a0;

    par {
        queenServer(a0, a1);
        antClient(field, &ant0, a0);
        antClient(field, &ant1, a1);
    }

    return 0;
}





