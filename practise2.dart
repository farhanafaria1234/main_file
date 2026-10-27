import 'dart:io';
void main(){
print('Welcome to dart!');

var myC = myClass();
myC.printName('Nishi');

myC.printName('Jubier');

myC.printName('Robin');
print (myC.add(5,7));
print (myC.add(600,700));

}
class myClass {
void printName(String name){
    print(name);
}
int add(int a,int b){
  int sum = a+b;
  return sum;
}

}